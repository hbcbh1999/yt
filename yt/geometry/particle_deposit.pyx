"""
Particle Deposition onto Cells

Author: Christopher Moody <chris.e.moody@gmail.com>
Affiliation: UC Santa Cruz
Author: Matthew Turk <matthewturk@gmail.com>
Affiliation: Columbia University
Homepage: http://yt.enzotools.org/
License:
  Copyright (C) 2013 Matthew Turk.  All Rights Reserved.

  This file is part of yt.

  yt is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.
"""

cimport numpy as np
import numpy as np
from libc.stdlib cimport malloc, free
cimport cython
from libc.math cimport sqrt

from fp_utils cimport *
from oct_container cimport Oct, OctAllocationContainer, \
    OctreeContainer, OctInfo

cdef class ParticleDepositOperation:
    def __init__(self, nvals):
        self.nvals = nvals

    def initialize(self, *args):
        raise NotImplementedError

    def finalize(self, *args):
        raise NotImplementedError

    def process_octree(self, OctreeContainer octree,
                     np.ndarray[np.int64_t, ndim=1] dom_ind,
                     np.ndarray[np.float64_t, ndim=2] positions,
                     fields = None, int domain_id = -1):
        cdef int nf, i, j
        if fields is None:
            fields = []
        nf = len(fields)
        cdef np.float64_t **field_pointers, *field_vals, pos[3]
        cdef np.ndarray[np.float64_t, ndim=1] tarr
        field_pointers = <np.float64_t**> alloca(sizeof(np.float64_t *) * nf)
        field_vals = <np.float64_t*>alloca(sizeof(np.float64_t) * nf)
        for i in range(nf):
            tarr = fields[i]
            field_pointers[i] = <np.float64_t *> tarr.data
        cdef int dims[3]
        dims[0] = dims[1] = dims[2] = 2
        cdef OctInfo oi
        cdef np.int64_t offset, moff
        cdef Oct *oct
        moff = octree.get_domain_offset(domain_id)
        for i in range(positions.shape[0]):
            # We should check if particle remains inside the Oct here
            for j in range(nf):
                field_vals[j] = field_pointers[j][i]
            for j in range(3):
                pos[j] = positions[i, j]
            oct = octree.get(pos, &oi)
            # This next line is unfortunate.  Basically it says, sometimes we
            # might have particles that belong to octs outside our domain.
            if oct.domain != domain_id: continue
            #print domain_id, oct.local_ind, oct.ind, oct.domain, oct.pos[0], oct.pos[1], oct.pos[2]
            # Note that this has to be our local index, not our in-file index.
            offset = dom_ind[oct.domain_ind - moff] * 8
            if offset < 0: continue
            # Check that we found the oct ...
            self.process(dims, oi.left_edge, oi.dds,
                         offset, pos, field_vals)
        
    def process_grid(self, gobj,
                     np.ndarray[np.float64_t, ndim=2] positions,
                     fields = None):
        cdef int nf, i, j
        if fields is None:
            fields = []
        nf = len(fields)
        cdef np.float64_t **field_pointers, *field_vals, pos[3]
        cdef np.ndarray[np.float64_t, ndim=1] tarr
        field_pointers = <np.float64_t**> alloca(sizeof(np.float64_t *) * nf)
        field_vals = <np.float64_t*>alloca(sizeof(np.float64_t) * nf)
        for i in range(nf):
            tarr = fields[i]
            field_pointers[i] = <np.float64_t *> tarr.data
        cdef np.float64_t dds[3], left_edge[3]
        cdef int dims[3]
        for i in range(3):
            dds[i] = gobj.dds[i]
            left_edge[i] = gobj.LeftEdge[i]
            dims[i] = gobj.ActiveDimensions[i]
        for i in range(positions.shape[0]):
            if i % 10000 == 0: print i, positions.shape[0]
            # Now we process
            for j in range(nf):
                field_vals[j] = field_pointers[j][i]
            for j in range(3):
                pos[j] = positions[i, j]
            self.process(dims, left_edge, dds, 0, pos, field_vals)

    cdef void process(self, int dim[3], np.float64_t left_edge[3],
                      np.float64_t dds[3], np.int64_t offset,
                      np.float64_t ppos[3], np.float64_t *fields):
        raise NotImplementedError

cdef class CountParticles(ParticleDepositOperation):
    cdef np.int64_t *count # float, for ease
    cdef public object ocount
    def initialize(self):
        # Create a numpy array accessible to python
        self.ocount = np.zeros(self.nvals, dtype="int64")
        cdef np.ndarray arr = self.ocount
        # alias the C-view for use in cython
        self.count = <np.int64_t*> arr.data

    @cython.cdivision(True)
    cdef void process(self, int dim[3],
                      np.float64_t left_edge[3], 
                      np.float64_t dds[3],
                      np.int64_t offset, # offset into IO field
                      np.float64_t ppos[3], # this particle's position
                      np.float64_t *fields # any other fields we need
                      ):
        # here we do our thing; this is the kernel
        cdef int ii[3], i
        for i in range(3):
            ii[i] = <int>((ppos[i] - left_edge[i])/dds[i])
        self.count[gind(ii[0], ii[1], ii[2], dim) + offset] += 1
        
    def finalize(self):
        return self.ocount.astype('f8')

deposit_count = CountParticles

cdef class SimpleSmooth(ParticleDepositOperation):
    # Note that this does nothing at the edges.  So it will give a poor
    # estimate there, and since Octrees are mostly edges, this will be a very
    # poor SPH kernel.
    cdef np.float64_t *data
    cdef public object odata
    cdef np.float64_t *temp
    cdef public object otemp

    def initialize(self):
        self.odata = np.zeros(self.nvals, dtype="float64")
        cdef np.ndarray arr = self.odata
        self.data = <np.float64_t*> arr.data
        self.otemp = np.zeros(self.nvals, dtype="float64")
        arr = self.otemp
        self.temp = <np.float64_t*> arr.data

    @cython.cdivision(True)
    cdef void process(self, int dim[3],
                      np.float64_t left_edge[3],
                      np.float64_t dds[3],
                      np.int64_t offset,
                      np.float64_t ppos[3],
                      np.float64_t *fields
                      ):
        cdef int ii[3], half_len, ib0[3], ib1[3]
        cdef int i, j, k
        cdef np.float64_t idist[3], kernel_sum, dist
        # Smoothing length is fields[0]
        kernel_sum = 0.0
        for i in range(3):
            ii[i] = <int>((ppos[i] - left_edge[i])/dds[i])
            half_len = <int>(fields[0]/dds[i]) + 1
            ib0[i] = ii[i] - half_len
            ib1[i] = ii[i] + half_len
            if ib0[i] >= dim[i] or ib1[i] <0:
                return
            ib0[i] = iclip(ib0[i], 0, dim[i] - 1)
            ib1[i] = iclip(ib1[i], 0, dim[i] - 1)
        for i from ib0[0] <= i <= ib1[0]:
            idist[0] = (ii[0] - i) * (ii[0] - i) * dds[0]
            for j from ib0[1] <= j <= ib1[1]:
                idist[1] = (ii[1] - j) * (ii[1] - j) * dds[1] 
                for k from ib0[2] <= k <= ib1[2]:
                    idist[2] = (ii[2] - k) * (ii[2] - k) * dds[2]
                    dist = idist[0] + idist[1] + idist[2]
                    # Calculate distance in multiples of the smoothing length
                    dist = sqrt(dist) / fields[0]
                    self.temp[gind(i,j,k,dim) + offset] = sph_kernel(dist)
                    kernel_sum += self.temp[gind(i,j,k,dim) + offset]
        # Having found the kernel, deposit accordingly into gdata
        for i from ib0[0] <= i <= ib1[0]:
            for j from ib0[1] <= j <= ib1[1]:
                for k from ib0[2] <= k <= ib1[2]:
                    dist = self.temp[gind(i,j,k,dim) + offset] / kernel_sum
                    self.data[gind(i,j,k,dim) + offset] += fields[1] * dist
        
    def finalize(self):
        return self.odata

deposit_simple_smooth = SimpleSmooth

cdef class SumParticleField(ParticleDepositOperation):
    cdef np.float64_t *sum
    cdef public object osum
    def initialize(self):
        self.osum = np.zeros(self.nvals, dtype="float64")
        cdef np.ndarray arr = self.osum
        self.sum = <np.float64_t*> arr.data

    @cython.cdivision(True)
    cdef void process(self, int dim[3],
                      np.float64_t left_edge[3], 
                      np.float64_t dds[3],
                      np.int64_t offset, 
                      np.float64_t ppos[3],
                      np.float64_t *fields 
                      ):
        cdef int ii[3], i
        for i in range(3):
            ii[i] = <int>((ppos[i] - left_edge[i]) / dds[i])
        self.sum[gind(ii[0], ii[1], ii[2], dim) + offset] += fields[0]
        
    def finalize(self):
        return self.osum

deposit_sum = SumParticleField

cdef class StdParticleField(ParticleDepositOperation):
    # Thanks to Britton and MJ Turk for the link
    # to a single-pass STD
    # http://www.cs.berkeley.edu/~mhoemmen/cs194/Tutorials/variance.pdf
    cdef np.float64_t *mk
    cdef np.float64_t *qk
    cdef np.float64_t *i
    cdef public object omk
    cdef public object oqk
    cdef public object oi
    def initialize(self):
        # we do this in a single pass, but need two scalar
        # per cell, M_k, and Q_k and also the number of particles
        # deposited into each one
        # the M_k term
        self.omk= np.zeros(self.nvals, dtype="float64")
        cdef np.ndarray omkarr= self.omk
        self.mk= <np.float64_t*> omkarr.data
        # the Q_k term
        self.oqk= np.zeros(self.nvals, dtype="float64")
        cdef np.ndarray oqkarr= self.oqk
        self.qk= <np.float64_t*> oqkarr.data
        # particle count
        self.oi = np.zeros(self.nvals, dtype="float64")
        cdef np.ndarray oiarr = self.oi
        self.i = <np.float64_t*> oiarr.data

    @cython.cdivision(True)
    cdef void process(self, int dim[3],
                      np.float64_t left_edge[3], 
                      np.float64_t dds[3],
                      np.int64_t offset,
                      np.float64_t ppos[3],
                      np.float64_t *fields
                      ):
        cdef int ii[3], i, cell_index
        cdef float k, mk, qk
        for i in range(3):
            ii[i] = <int>((ppos[i] - left_edge[i])/dds[i])
        cell_index = gind(ii[0], ii[1], ii[2], dim) + offset
        k = self.i[cell_index] 
        mk = self.mk[cell_index]
        qk = self.qk[cell_index] 
        #print k, mk, qk, cell_index
        if k == 0.0:
            # Initialize cell values
            self.mk[cell_index] = fields[0]
        else:
            self.mk[cell_index] = mk + (fields[0] - mk) / k
            self.qk[cell_index] = qk + (k - 1.0) * (fields[0] - mk)**2.0 / k
        self.i[cell_index] += 1
        
    def finalize(self):
        # This is the standard variance
        # if we want sample variance divide by (self.oi - 1.0)
        std2 = self.oqk / self.oi
        std2[self.oi == 0.0] = 0.0
        return np.sqrt(std2)

deposit_std = StdParticleField

