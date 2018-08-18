# Copyright (c) 2010-2018 The Regents of the University of Michigan
# This file is from the freud project, released under the BSD 3-Clause License.

R"""
Modules for calculating quantities in reciprocal space, including Fourier
transforms of shapes and diffraction pattern generation.
"""

import numpy as np
import math
import copy

from freud._cy_kspace import FTdelta as _FTdelta
from freud._cy_kspace import FTsphere as _FTsphere
from freud._cy_kspace import FTpolyhedron as _FTpolyhedron
import freud.common


def meshgrid2(*arrs):
    """Computes an n-dimensional meshgrid.

    source: http://stackoverflow.com/questions/1827489/numpy-meshgrid-in-3d

    Args:
        arrs (list): Arrays to meshgrid.

    Returns:
        :class:`tuple`: Tuple of arrays.
    """
    arrs = tuple(reversed(arrs))
    lens = list(map(len, arrs))
    dim = len(arrs)

    sz = 1
    for s in lens:
        sz *= s

    ans = []
    for i, arr in enumerate(arrs):
        slc = [1] * dim
        slc[i] = lens[i]
        arr2 = np.asarray(arr).reshape(slc)
        for j, sz in enumerate(lens):
            if j != i:
                arr2 = arr2.repeat(sz, axis=j)
        ans.append(arr2)

    return tuple(ans[::-1])


class SFactor3DPoints:
    """Compute the full 3D structure factor of a given set of points.

    Given a set of points :math:`\\vec{r}_i`, SFactor3DPoints computes the
    static structure factor :math:`S \\left( \\vec{q} \\right) = C_0 \\left|
    {\\sum_{m=1}^{N} e^{\\mathit{i}\\vec{q}\\cdot\\vec{r_i}}} \\right|^2`.

    In this expression, :math:`C_0` is a scaling constant chosen so that
    :math:`S\\left(0\\right) = 1`, and :math:`N` is the number of particles.

    :math:`S` is evaluated on a grid of :math:`q`-values :math:`\\vec{q} = h
    \\frac{2\\pi}{L_x} \\hat{i} + k \\frac{2\\pi}{L_y} \\hat{j} + l
    \\frac{2\\pi}{L_z} \\hat{k}` for integer :math:`h,k,l: \\left[-g,g\\right]`
    and :math:`L_x, L_y, L_z` are the box lengths in each direction.

    After calling :py:meth:`~.SFactor3DPoints.compute()`, access the :math:`q`
    values with :py:meth:`~.SFactor3DPoints.getQ()`, the static structure
    factor values with :py:meth:`~.SFactor3DPoints.getS()`, and (if needed)
    the un-squared complex version of :math:`S` with
    :py:meth:`~.SFactor3DPoints.getSComplex()`. All values are stored in 3D
    :class:`numpy.ndarray` structures. They are indexed by :math:`a, b, c`
    where :math:`a=h+g, b=k+g, c=l+g`.

    .. note::
        Due to the way that numpy arrays are indexed, access the returned
        S array as :code:`S[c,b,a]` to get the value at
        :math:`q = \\left(qx\\left[a\\right], qy\\left[b\\right],
        qz\\left[c\\right]\\right)`.

    Args:
        box (:py:class:`freud.box.Box`):
            The simulation box.
        g (int):
            The number of grid points for :math:`q` in each direction is 2*g+1.

    """

    def __init__(self, box, g):
        """Initalize SFactor3DPoints."""
        box = freud.common.convert_box(box)
        if box.is2D():
            raise ValueError("SFactor3DPoints does not support 2D boxes")
        self.grid = 2 * g + 1
        self.qx = np.linspace(-g * 2 * math.pi / box.getLx(),
                              g * 2 * math.pi / box.getLx(), num=self.grid)
        self.qy = np.linspace(-g * 2 * math.pi / box.getLy(),
                              g * 2 * math.pi / box.getLy(), num=self.grid)
        self.qz = np.linspace(-g * 2 * math.pi / box.getLz(),
                              g * 2 * math.pi / box.getLz(), num=self.grid)

        # make meshgrid versions of qx,qy,qz for easy computation later
        self.qx_grid, self.qy_grid, self.qz_grid = meshgrid2(
            self.qx, self.qy, self.qz)

        # initialize a 0 S
        self.s_complex = np.zeros(
            shape=(self.grid, self.grid, self.grid), dtype=np.complex64)

    def compute(self, points):
        """Compute the static structure factor of a given set of points.

        After calling :py:meth:`~.SFactor3DPoints.compute()`, you can access
        the results with :py:meth:`~.SFactor3DPoints.getS()`,
        :py:meth:`~.SFactor3DPoints.getSComplex()`, and the grid with
        :py:meth:`~.SFactor3DPoints.getQ()`.

        Args:
            points ((:math:`N_{particles}`, 3) :class:`numpy.ndarray`):
                Points used to compute the static structure factor.
        """
        # clear s_complex to zero
        self.s_complex[:, :, :] = 0

        # add the contribution of each point
        for p in points:
            self.s_complex += np.exp(1j * (
                self.qx_grid * p[0]
                + self.qy_grid * p[1]
                + self.qz_grid * p[2]))

        # normalize
        mid = self.grid // 2
        cinv = np.absolute(self.s_complex[mid, mid, mid])
        self.s_complex /= cinv
        return self

    def getS(self):
        """Get the computed static structure factor.

        Returns:
            (X, Y) :class:`numpy.ndarray`:
                The computed static structure factor as a copy.
        """
        return (self.s_complex * np.conj(self.s_complex)).astype(
            np.float32)

    def getSComplex(self):
        """Get the computed complex structure factor (if you need the phase
        information).

        Returns:
            (X, Y) :class:`numpy.ndarray`:
                The computed static structure factor, as a copy, without taking
                the magnitude squared.
        """
        return copy.cpy(self.s_complex)

    def getQ(self):
        """Get the :math:`q` values at each point.

        The structure factor :code:`S[c,b,a]` is evaluated at the vector
        :math:`q = \\left(qx\\left[a\\right], qy\\left[b\\right],
        qz\\left[c\\right]\\right)`.

        Returns:
            tuple: (qx, qy, qz).
        """
        return (self.qx, self.qy, self.qz)


class AnalyzeSFactor3D:
    """Analyze the peaks in a 3D structure factor.

    Given a structure factor :math:`S\\left(q\\right)` computed by classes
    such as :py:class:`~.SFactor3DPoints`, :py:class:`~.AnalyzeSFactor3D`
    performs a variety of analysis tasks.

        * Identifies peaks.
        * Provides a list of peaks and the vector :math:`\\vec{q}` positions
          at which they occur.
        * Provides a list of peaks grouped by :math:`q^2`
        * Provides a full list of :math:`S\\left(\\left|q\\right|\\right)`
          values vs :math:`q^2` suitable for plotting the 1D analog of the
          structure factor.
        * Scans through the full 3D peaks and reconstructs the Bravais lattice.

    .. note::
        All of these operations work in an indexed integer :math:`q`-space
        :math:`h,k,l`. Any peak position values returned must be multiplied by
        :math:`2\\pi/L` to get to real :math:`q` values in simulation units.

    .. todo::
        need to think if this actually will work with non-cubic boxes...

    Args:
        S (:class:`numpy.ndarray`): Static structure factor to analyze.
    """

    def __init__(self, S):
        """Initialize the analyzer."""
        self.S = S
        self.grid = S.shape[0]
        self.g = self.grid // 2

    def getPeakList(self, cut):
        """Get a list of peaks in the structure factor.

        Args:
            cut (float):
                All :math:`S\\left(q\\right)` values greater than cut will be
                counted as peaks.

        Returns:
            list: peaks, :math:`q` as lists.

        """
        clist, blist, alist = (self.S > cut).nonzero()
        clist -= self.g
        blist -= self.g
        alist -= self.g

        q_list = [idx for idx in zip(clist, blist, alist)]
        peak_list = [self.S[(q[0] + self.g,
                             q[1] + self.g,
                             q[2] + self.g)]
                     for q in q_list]
        return (q_list, peak_list)

    def getPeakDegeneracy(self, cut):
        """Get a dictionary of peaks indexed by :math:`q^2`.

        Args:
            cut (:class:`numpy.ndarray`):
                All :math:`S\\left(q\\right)` values greater than cut will be
                counted as peaks.

        Returns:
            dict:
                A dictionary with keys :math:`q^2` and a list of peaks for the
                corresponding values.
        """
        q_list, peak_list = self.getPeakList(cut)

        retval = {}
        for q, peak in zip(q_list, peak_list):
            qsq = q[0] * q[0] + q[1] * q[1] + q[2] * q[2]
            if not (qsq in retval):
                retval[qsq] = []

            retval[qsq].append(peak)

        return retval

    def getSvsQ(self):
        """Get a list of all :math:`S\\left(\\left|q\\right|\\right)` values vs
        :math:`q^2`.

        Returns:
            :class:`numpy.ndarray`: S, qsquared.
        """
        hx = range(-self.g, self.g + 1)

        qsq_list = []
        # create an list of q^2 in the proper order
        for i in range(0, self.grid):
            for j in range(0, self.grid):
                for k in range(0, self.grid):
                    qsq_list.append(hx[i] * hx[i] +
                                    hx[j] * hx[j] +
                                    hx[k] * hx[k])

        return (self.S.flatten(), qsq_list)


class SingleCell3D:
    """SingleCell3D objects manage data structures necessary to call the
    Fourier Transform functions that evaluate FTs for given form factors at a
    list of :math:`K` points. SingleCell3D provides an interface to helper
    functions to calculate :math:`K` points for a desired grid from the
    reciprocal lattice vectors calculated from an input boxMatrix.
    State is maintained as `set_` and `update_` functions invalidate internal
    data structures and as fresh data is restored with `update_` function
    calls. This should facilitate management with a higher-level UI such as a
    GUI with an event queue.

    I'm not sure what sort of error checking would be most useful, so I'm
    mostly allowing ValueErrors and such exceptions to just occur and then
    propagate up through the calling functions to be dealt with by the user.

    Args:
        ndiv (int):
            The resolution of the diffraction image grid.
        k (float):
            The angular wave number of the plane wave probe (Currently unused).
        dK (float):
            The k-space unit associated with the diffraction image grid
            spacing.
        boxMatrix ((:math:`N_{particles}`, 3) :class:`numpy.ndarray`):
            The unit cell lattice vectors as columns in a 3x3 matrix.
        scale (float):
            nm per unit length (default 1.0).

    .. note::
        * The `set_` functions take a single parameeter and cause other
          internal data structures to become invalid.
        * The `update_` and calculate functions restore the validity of
          these structures using internal data.
        * The functions are separate to make it easier to avoid unnecessary
          computation such as when changing multiple parameters before
          seeking output or when wrapping the code with an interface
          with an event queue.
    """

    def __init__(self, k=1800, ndiv=16, dK=0.01, boxMatrix=None,
                 *args, **kwargs):
        """Initialize the single-cell data structure for FT calculation."""
        # Initialize some state
        self.Kpoints_valid = False
        self.FT_valid = False
        self.bases_valid = False
        self.K_constraint_valid = False

        # Set up particle type data structures
        self.ptype_name = list()
        self.ptype_position = list()
        self.ptype_orientation = list()
        self.ptype_ff = list()
        self.ptype_param = dict()
        self.ptype_param_methods = list()
        self.active_types = set()

        # Get arguments
        self.k = np.float32(k)
        self.ndiv = np.float32(ndiv)
        self.dK = np.float32(dK)
        if np.float32(boxMatrix).shape != (3, 3):
            raise ValueError('Need a valid box matrix!')
        else:
            self.boxMatrix = boxMatrix
        if 'scale' in kwargs:
            self.scale = kwargs['scale']
        else:
            self.scale = 1.0
        self.scale = np.float32(self.scale)
        self.a1, self.a2, self.a3 = np.zeros((3, 3), dtype=np.float32)
        self.g1, self.g2, self.g3 = np.zeros((3, 3), dtype=np.float32)
        self.update_bases()

        # Initialize remaining variables
        self.FT = None
        self.Kpoints = None
        self.Kmax = np.float32(self.dK * self.ndiv)
        K = self.Kmax
        epsilon = np.float32(-0.5 * self.dK)
        self.K_extent = [-K, K, -K, K, -epsilon, epsilon]
        self.K_constraint = None

        # For initial K points, assume a planar extent commensurate with the
        # image
        self.update_K_constraint()
        self.update_Kpoints()

        # Set up particle type information and scattering form factor mapping
        self.fffactory = FTfactory()

    def add_ptype(self, name):
        """Create internal data structures for new particle type by name.

        Particle type is inactive when added because parameters must be set
        before FT can be performed.

        Args:
            name (str): particle name
        """
        if name in self.ptype_name:
            raise ValueError('{name} already exists'.format(name=name))
        self.ptype_name.append(name)
        self.ptype_position.append(np.empty((0, 3), dtype=np.float32))
        self.ptype_orientation.append(np.empty((0, 4), dtype=np.float32))
        self.ptype_ff.append(None)
        for param in self.ptype_param:
            self.ptype_param[param].append(None)

    def remove_ptype(self, name):
        """Remove internal data structures associated with ptype :code:`name`.

        Args:
            name (str): Particle type to remove.

        .. note::
            This shouldn't usually be necessary, since particle types may be
            set inactive or have any of their properties updated through
            `set_` methods.
        """
        i = self.ptype_name.index(name)
        if i in self.active_types:
            self.active_types.remove(i)
        for param in self.ptype_param:
            self.ptype_param[param].remove(i)
        self.ptype_param_methods.remove(i)
        self.ptype_ff.remove(i)
        self.ptype_orientation.remove(i)
        self.ptype_position.remove(i)
        self.ptype_name.remove(i)
        if i in self.active_types:
            self.FT_valid = False

    def set_active(self, name):
        """Set particle type active.

        Args:
            name (str): Particle name.
        """
        i = self.ptype_name.index(name)
        if i not in self.active_types:
            self.active_types.add(i)
            self.FT_valid = False

    def set_inactive(self, name):
        """Set particle type inactive.

        Args:
            name (str): Particle name.
        """
        i = self.ptype_name.index(name)
        if i in self.active_types:
            self.active_types.remove(i)
            self.FT_valid = False

    def get_ptypes(self):
        """Get ordered list of particle names.

        Returns:
            list: List of particle names.
        """
        return self.ptype_name

    def get_form_factors(self):
        """Get form factor names and indices.

        Returns:
            list: List of factor names and indices.
        """
        return self.fffactory.getFTlist()

    def set_form_factor(self, name, ff):
        """Set scattering form factor.

        Args:
            name (str):
                Particle type name.
            ff (str):
                Scattering form factor named in
                :py:meth:`~.SingleCell3D.get_form_factors()`.
        """
        i = self.ptype_name.index(name)
        j = self.fffactory.getFTlist().index(ff)
        FTobj = self.fffactory.getFTobject(j)
        # set FTobj parameters with previously chosen values
        for param in self.ptype_param:
            if param in FTobj.get_params():
                value = self.ptype_param[param][i]
                FTobj.set_parambyname(param, value)
        FTobj.set_parambyname('scale', self.scale)
        FTobj.set_rq(self.ptype_position[i], self.ptype_orientation[i])
        FTobj.set_K(self.Kpoints)
        self.ptype_ff[i] = FTobj
        if i in self.active_types:
            self.FT_valid = False

    def set_param(self, particle, param, value):
        """Set named parameter for named particle.

        Args:
            particle (str): Particle name.
            param (str): Parameter name.
            value (float): Parameter value.
        """
        i = self.ptype_name.index(particle)
        FTobj = self.ptype_ff[i]
        if param not in self.ptype_param:
            self.ptype_param[param] = [None] * len(self.ptype_name)
        self.ptype_param[param][i] = value
        if param not in FTobj.get_params():
            raise KeyError('No set_ method for parameter {p}'.format(p=param))
        else:
            FTobj.set_parambyname(param, value)
            if i in self.active_types:
                self.FT_valid = False

    def set_scale(self, scale):
        """Set scale factor. Store global value and set for each particle type.

        Args:
            scale (float): nm per unit for input file coordinates.
        """
        self.scale = np.float32(scale)
        for i in range(len(self.ptype_ff)):
            self.ptype_ff[i].set_scale(scale)
        self.bases_valid = False

    def set_box(self, boxMatrix):
        """Set box matrix.

        Args:
            boxMatrix ((3, 3) :class:`numpy.ndarray`): Unit cell box matrix.
        """
        self.boxMatrix = np.array(boxMatrix)
        self.bases_valid = False

    def set_rq(self, name, position, orientation):
        """Set positions and orientations for a particle type.

        To best maintain valid state in the event of changing numbers of
        particles, position and orientation are updated in a single method.

        Args:
            name (str):
                Particle type name.
            position ((N,3) :class:`numpy.ndarray`):
                Array of particle positions.
            orientation ((N,4) :class:`numpy.ndarray`):
                Array of particle quaternions.
        """
        i = self.ptype_name.index(name)
        r = np.asarray(position, dtype=np.float32)
        q = np.asarray(orientation, dtype=np.float32)
        # Check for compatible position and orientation
        N = r.shape[0]
        if q.shape[0] != N:
            raise ValueError(
                'position and orientation must be the same length')
        if r.ndim != 2 or r.shape[1] != 3:
            raise ValueError('position must be a (N,3) array')
        if q.ndim != 2 or q.shape[1] != 4:
            raise ValueError('orientation must be a (N,4) array')
        self.ptype_position[i] = r
        self.ptype_orientation[i] = q
        self.ptype_ff[i].set_rq(r, q)
        if i in self.active_types:
            self.FT_valid = False

    def set_ndiv(self, ndiv):
        """Set number of grid divisions in diffraction image.

        Args:
            ndiv (int): Define diffraction image as ndiv x ndiv grid.
        """
        self.ndiv = int(ndiv)
        self.K_constraint_valid = False

    def set_dK(self, dK):
        """Set grid spacing in diffraction image.

        Args:
            dK (float):
                Difference in :math:`K` vector between two adjacent diffraction
                image grid points.
        """
        self.dK = np.float32(dK)
        self.K_constraint_valid = False

    def set_k(self, k):
        """Set angular wave number of plane wave probe.

        Args:
            k (float): :math:`\\left|k_0\\right|`.
        """
        self.k = np.float32(k)

    def update_bases(self):
        """Update the direct and reciprocal space lattice vectors.

        .. note::
            If scale or boxMatrix is updated, the lattice vectors in direct and
            reciprocal space need to be recalculated.

        .. todo::
            call automatically if scale, boxMatrix updated
        """
        self.bases_valid = True
        # Calculate scaled lattice vectors
        vectors = self.boxMatrix.transpose() * self.scale
        self.a1, self.a2, self.a3 = np.float32(vectors)
        # Calculate reciprocal lattice vectors
        self.g1, self.g2, self.g3 = np.float32(
            reciprocalLattice3D(self.a1, self.a2, self.a3))
        self.K_constraint_valid = False

    def update_K_constraint(self):
        """Recalculate constraint used to select :math:`K` values.

        The constraint used is a slab of epsilon thickness in a plane
        perpendicular to the :math:`k_0` propagation, intended to provide easy
        emulation of TEM or relatively high-energy scattering.
        """
        self.K_constraint_valid = True
        self.Kmax = np.float32(self.dK * self.ndiv)
        K = self.Kmax
        R = K * np.float32(np.sqrt(2))
        epsilon = np.abs(np.float32(0.5 * self.dK))
        self.K_extent = [-K, K, -K, K, -epsilon, epsilon]
        self.K_constraint = AlignedBoxConstraint(R, *self.K_extent)
        self.Kpoints_valid = False

    def update_Kpoints(self):
        """Update :math:`K` points at which to evaluate FT.

        .. note::
            If the diffraction image dimensions change relative to the
            reciprocal lattice, the :math:`K` points need to be recalculated.
        """
        self.Kpoints_valid = True
        self.Kpoints = np.float32(constrainedLatticePoints(
            self.g1, self.g2, self.g3, self.K_constraint))
        for i in range(len(self.ptype_ff)):
            self.ptype_ff[i].set_K(self.Kpoints)
        self.FT_valid = False

    def calculate(self, *args, **kwargs):
        """Calculate FT. The details and arguments will vary depending on
        the form factor chosen for the particles.

        For any particle type-dependent parameters passed as keyword arguments,
        the parameter must be passed as a list of length :code:`max(p_type)+1`
        with indices corresponding to the particle types defined. In other
        words, type-dependent parameters are optional (depending on the set of
        form factors being calculated), but if included must be defined for all
        particle types.
        """
        self.FT_valid = True
        shape = (len(self.Kpoints),)
        self.FT = np.zeros(shape, dtype=np.complex64)
        for i in self.active_types:
            calculator = self.ptype_ff[i]
            calculator.compute()
            self.FT += calculator.getFT()
        return self.FT


class FTfactory:
    """Factory to return an FT object of the requested type."""

    def __init__(self):
        self.name_list = ['Delta']
        self.constructor_list = [FTdelta]
        self.args_list = [None]

    def getFTlist(self):
        """Get an ordered list of named FT types.

        Returns:
            list: List of FT names.
        """
        return self.name_list

    def getFTobject(self, i, args=None):
        """Get a new instance of an FT type from list returned by
        :py:meth:`~.FTfactory.getFTlist()`.

        Args:
            i (int):
                Index into list returned by :py:meth:`~.FTfactory.getFTlist()`.
            args:
                Argument object used to initialize FT, overriding default set
                at :py:meth:`~.FTfactory.addFT()`.
        """
        constructor = self.constructor_list[i]
        if args is None:
            args = self.args_list[i]
        return constructor(args)

    def addFT(self, name, constructor, args=None):
        """Add an FT class to the factory.

        Args:
            name (str):
                Identifying string to be returned by getFTlist().
            constructor (str):
                Class / function name to be used to create new FT objects.
            args (list):
                Set default argument object to be used to construct FT objects.
        """
        if name in self.name_list:
            raise ValueError('{name} already in factory'.format(name=name))
        else:
            self.name_list.append(name)
            self.constructor_list.append(constructor)
            self.args_list.append(args)


class FTbase:
    """Base class for FT calculation classes."""

    def __init__(self, *args, **kwargs):
        self.scale = np.float32(1.0)
        self.density = np.complex64(1.0)
        self.S = None
        self.K = np.array([[0., 0., 0.]], dtype=np.float32)
        self.position = np.array([[0., 0., 0.]], dtype=np.float32)
        self.orientation = np.array([[1., 0., 0., 0.]], dtype=np.float32)

        # create dictionary of parameter names and set/get methods
        self.set_param_map = dict()
        self.set_param_map['scale'] = self.set_scale
        self.set_param_map['density'] = self.set_density

        self.get_param_map = dict()
        self.get_param_map['scale'] = self.get_scale
        self.get_param_map['density'] = self.get_density

    # Compute FT
    # def compute(self, *args, **kwargs):
    def getFT(self):
        """Return Fourier Transform.

        Returns:
            :class:`numpy.ndarray`: Fourier Transform.
        """
        return self.S

    def get_params(self):
        """Get the parameter names accessible with
        :py:meth:`~.FTbase.set_parambyname()`.

        Returns:
            list: Parameter names.
        """
        return self.set_param_map.keys()

    def set_parambyname(self, name, value):
        """Set named parameter for object.

        Args:
            name (str):
                Parameter name. Must exist in list returned by
                :py:meth:`~.FTbase.get_params()`.
            value (float):
                Parameter value to set.
        """
        if name not in self.set_param_map.keys():
            msg = 'Object {type} does not have parameter {param}'.format(
                type=self.__class__, param=name)
            raise KeyError(msg)
        else:
            self.set_param_map[name](value)

    def get_parambyname(self, name):
        """Get named parameter for object.

        Args:
            name (str):
                Parameter name. Must exist in list returned by
                :py:meth:`~.FTbase.get_params()`.

        Returns:
            float: Parameter value.
        """
        if name not in self.get_param_map.keys():
            msg = 'Object {type} does not have parameter {param}'.format(
                type=self.__class__, param=name)
            raise KeyError(msg)
        else:
            return self.get_param_map[name]()

    def set_K(self, K):
        """Set :math:`K` points to be evaluated.

        Args:
            K (:class:`numpy.ndarray`):
                List of :math:`K` vectors at which to evaluate FT.
        """
        self.K = np.asarray(K, dtype=np.float32)

    def set_scale(self, scale):
        """Set scale.

        Args:
            scale (float): Scale.
        """
        self.scale = np.float32(scale)

    def get_scale(self):
        """Get scale.

        Returns:
            float: Scale.
        """
        return self.scale

    def set_density(self, density):
        """Set density.

        Args:
            density (:class:`numpy.complex64`): Density.
        """
        self.density = np.complex64(density)

    def get_density(self):
        """Get density.

        Returns:
            :class:`numpy.complex64`: Density.
        """
        return self.density

    def set_rq(self, r, q):
        """Set :math:`r`, :math:`q` values.

        Args:
            r (float): :math:`r`.
            q (float): :math:`q`.
        """
        self.position = np.asarray(r, dtype=np.float32)
        self.orientation = np.asarray(q, dtype=np.float32)
        if self.position.ndim == 1:
            self.position.resize((1, 3))
        if self.position.ndim != 2:
            print('Error: can not make an array of 3D vectors'
                  'from input position.')
            return None
        if self.orientation.ndim == 1:
            self.orientation.resize((1, 4))
        if self.orientation.ndim != 2:
            print('Error: can not make an array of 4D vectors'
                  'from input orientation.')
            return None


class FTdelta(FTbase):
    """Fourier transform a list of delta functions."""

    def __init__(self, *args, **kwargs):
        FTbase.__init__(self)
        self.FTobj = _FTdelta()

    def set_K(self, K):
        """Set :math:`K` points to be evaluated.

        Args:
            K (:class:`numpy.ndarray`):
                List of :math:`K` vectors at which to evaluate FT.
        """
        FTbase.set_K(self, K)
        self.FTobj.set_K(self.K * self.scale)

    def set_scale(self, scale):
        """Set scale.

        Args:
            scale (float): Scale.

        .. note::
            For a scale factor, :math:`\\lambda`, affecting the scattering
            density :math:`\\rho\\left(r\\right)`, :math:`S_{\\lambda}\\left
            (k\\right) == \\lambda^3 * S\\left(\\lambda * k\\right)`
        """
        FTbase.set_scale(self, scale)
        # self.FTobj.set_scale(float(self.scale))
        self.FTobj.set_K(self.K * self.scale)

    def set_density(self, density):
        """Set density.

        Args:
            density (:class:`numpy.complex64`): density
        """
        FTbase.set_density(self, density)
        self.FTobj.set_density(complex(self.density))

    def set_rq(self, r, q):
        """Set :math:`r`, :math:`q` values.

        Args:
            r (float): :math:`r`.
            q (float): :math:`q`.
        """
        FTbase.set_rq(self, r, q)
        self.FTobj.set_rq(self.position, self.orientation)

    def compute(self, *args, **kwargs):
        """Compute FT.

        Calculate :math:`S = \\sum_{\\alpha} e^{-i \\mathbf{K} \\cdot
        \\mathbf{r}_{\\alpha}}`.
        """
        self.FTobj.compute()
        self.S = self.FTobj.getFT() * self.scale**3
        return self


class FTsphere(FTdelta):
    """Fourier transform for sphere.

    Calculate :math:`S = \\sum_{\\alpha} e^{-i \\mathbf{K} \\cdot
    \\mathbf{r}_{\\alpha}}`.
    """

    def __init__(self, *args, **kwargs):
        FTbase.__init__(self, *args, **kwargs)
        self.FTobj = _FTsphere()
        self.set_param_map['radius'] = self.set_radius
        self.get_param_map['radius'] = self.get_radius
        self.set_radius(0.5)

    def set_radius(self, radius):
        """Set radius parameter.

        Args:
            radius (float):
                Sphere radius will be stored as given, but scaled by scale
                parameter when used by methods.
        """
        self.radius = float(radius)
        self.FTobj.set_radius(self.radius)

    def get_radius(self):
        """Get radius parameter.

        If appropriate, return value should be scaled by
        :code:`get_parambyname('scale')` for interpretation.

        Returns:
            float: Unscaled radius.
        """
        self.radius = self.FTobj.get_radius()
        return self.radius


class FTpolyhedron(FTbase):
    """Fourier Transform for polyhedra."""

    def __init__(self, *args, **kwargs):
        FTbase.__init__(self, *args, **kwargs)
        self.FTobj = _FTpolyhedron()
        self.set_param_map['radius'] = self.set_radius
        self.get_param_map['radius'] = self.get_radius

    def set_K(self, K):
        """Set :math:`K` points to be evaluated.

        Args:
            K (:class:`numpy.ndarray`):
                List of :math:`K` vectors at which to evaluate FT.
        """
        FTbase.set_K(self, K)
        self.FTobj.set_K(self.K * self.scale)

    def set_rq(self, r, q):
        """Set :math:`r`, :math:`q` values.

        Args:
            r (float): :math:`r`.
            q (float): :math:`q`.
        """
        FTbase.set_rq(self, r, q)
        self.FTobj.set_rq(self.position, self.orientation)

    def set_density(self, density):
        """Set density.

        Args:
            density (:class:`numpy.complex64`): Density.
        """
        FTbase.set_density(self, density)
        self.FTobj.set_density(complex(self.density))

    def set_params(self, verts, facets, norms, d, areas, volume):
        """Construct list of facet offsets.

        Args:
            verts ((:math:`N_{particles}`, 3) :class:`numpy.ndarray`):
                Vertex coordinates.
            facets ((:math:`N_{facets}`, 3) :class:`numpy.ndarray`):
                Facet vertex indices.
            norms ((:math:`N_{facets}`, 3) :class:`numpy.ndarray`):
                Facet normals.
            d ((:math:`N_{facets}-1`) :class:`numpy.ndarray`):
                Facet distances.
            area ((:math:`N_{facets}-1`) :class:`numpy.ndarray`):
                Facet areas.
            volume (float):
                Polyhedron volume.
        """
        facet_offs = np.zeros((len(facets) + 1), dtype=np.uint32)
        for i, f in enumerate(facets):
            facet_offs[i + 1] = facet_offs[i] + len(f)
        self.FTobj.set_params(verts, facet_offs, np.array(
            [vi for f in facets for vi in f], dtype=np.uint32), norms, d,
            areas, volume)

    def set_radius(self, radius):
        """Set radius of in-sphere.

        Args:
            radius (float):
                Radius of inscribed sphere without scale applied.
        """
        # Find original in-sphere radius, determine necessary scale factor, and
        # scale vertices and surface distances
        radius = float(radius)
        self.hull.setInsphereRadius(radius)

    def get_radius(self):
        """Get radius parameter.

        If appropriate, return value should be scaled by
        :code:`get_parambyname('scale')` for interpretation.

        Returns:
            float: Unscaled radius.
        """
        # Find current in-sphere radius
        inradius = self.hull.getInsphereRadius()
        return inradius

    def compute(self, *args, **kwargs):
        """Compute FT.

        Calculate :math:`S = \\sum_{\\alpha} e^{-i \\mathbf{K} \\cdot
        \\mathbf{r}_{\\alpha}}`.
        """
        self.FTobj.compute()
        self.S = self.FTobj.getFT() * self.scale**3
        return self


class FTconvexPolyhedron(FTpolyhedron):
    """Fourier Transform for convex polyhedra.

    Args:
        hull ((:math:`N_{verts}`, 3) :class:`numpy.ndarray`):
            Convex hull object.
    """

    def __init__(self, hull, *args, **kwargs):
        FTpolyhedron.__init__(self, *args, **kwargs)
        self.set_param_map['radius'] = self.set_radius
        self.get_param_map['radius'] = self.get_radius
        self.hull = hull

        # set convex hull geometry
        verts = self.hull.points * self.scale
        facets = [self.hull.facets[i, 0:n]
                  for (i, n) in enumerate(self.hull.nverts)]
        norms = self.hull.equations[:, 0:3]
        d = - self.hull.equations[:, 3] * self.scale
        area = [self.hull.getArea(i) * self.scale**2.0
                for i in range(len(facets))]
        volume = self.hull.getVolume() * self.scale**3.0
        self.set_params(verts, facets, norms, d, area, volume)

    def set_radius(self, radius):
        """Set radius of in-sphere.

        Args:
            radius (float):
                Radius of inscribed sphere without scale applied.
        """
        # Find original in-sphere radius, determine necessary scale factor,
        # and scale vertices and surface distances
        radius = float(radius)
        self.hull.setInsphereRadius(radius)

    def get_radius(self):
        """Get radius parameter.

        If appropriate, return value should be scaled by
        get_parambyname('scale') for interpretation.

        Returns:
            float: Unscaled radius.
        """
        # Find current in-sphere radius
        inradius = self.hull.getInsphereRadius()
        return inradius

    def compute_py(self, *args, **kwargs):
        """Compute FT.

        Calculate :math:`P = F * S`:

        * :math:`S = \\sum_{\\alpha} e^{-i \\mathbf{K} \\cdot \
          \\mathbf{r}_{\\alpha}}`.
        * F is the analytical form factor for a polyhedron,
          computed with :py:meth:`~.FTconvexPolyhedron.Spoly3D()`.
        """
        # Return FT of delta function at one or more locations
        position = self.scale * self.position
        orientation = self.orientation
        self.outputShape = (self.K.shape[0],)
        self.S = np.zeros(self.outputShape, dtype=np.complex64)
        for r, q in zip(position, orientation):
            for i in range(len(self.K)):
                # The FT of an object with orientation q at a given k-space
                # point is the same as the FT of the unrotated object at a
                # k-space point rotated the opposite way. The opposite of the
                # rotation represented by a quaternion is the conjugate of the
                # quaternion, found by inverting the sign of the imaginary
                # components.
                K = quatrot(q * np.array([1, -1, -1, -1]), self.K[i])
                self.S[i] += np.exp(np.dot(K, r) *
                                    -1.j) * self.Spoly3D(K)
        self.S *= self.density
        return self

    def Spoly2D(self, i, k):
        """Calculate Fourier transform of polygon.

        Args:
            i (float):
                Face index into self.hull simplex list.
            k (:class:`numpy.ndarray`):
                Angular wave vector at which to calculate
                :math:`S\\left(i\\right)`.
        """
        if np.dot(k, k) == 0.0:
            S = self.hull.getArea(i) * self.scale**2
        else:
            S = 0.0
            nverts = self.hull.nverts[i]
            verts = list(self.hull.facets[i, 0:nverts])
            # apply periodic boundary condition for convenience
            verts.append(verts[0])
            points = self.hull.points * self.scale
            n = self.hull.equations[i, 0:3]
            for j in range(self.hull.nverts[i]):
                v1 = points[verts[j + 1]]
                v0 = points[verts[j]]
                edge = v1 - v0
                centrum = np.array((v1 + v0) / 2.)
                # Note that np.sinc(x) gives sin(pi*x)/pi*x
                x = np.dot(k, edge) / np.pi
                cpedgek = np.cross(edge, k)
                S += np.dot(n, cpedgek) * np.exp(
                    -1.j * np.dot(k, centrum)) * np.sinc(x)
            S *= (-1.j / np.dot(k, k))
        return S

    def Spoly3D(self, k):
        """Calculate Fourier transform of polyhedron.

        Args:
            k (int):
                Angular wave vector at which to calculate
                :math:`S\\left(i\\right)`.
        """
        if np.dot(k, k) == 0.0:
            S = self.hull.getVolume() * self.scale**3
        else:
            S = 0.0
            # for face in faces
            for i in range(self.hull.nfacets):
                # need to project k into plane of face
                ni = self.hull.equations[i, 0:3]
                di = - self.hull.equations[i, 3] * self.scale
                dotkni = np.dot(k, ni)
                k_proj = k - ni * dotkni
                S += dotkni * np.exp(-1.j * dotkni * di) * \
                    self.Spoly2D(i, k_proj)
            S *= 1.j / (np.dot(k, k))
        return S


def rotate(v, u, theta):
    """Axis-angle rotation.

    Args:
        v (:class:`numpy.ndarray`): Vector to rotate.
        u (:class:`numpy.ndarray`): Rotation axis.
        theta (float): Rotation angle.
    """
    v = np.array(v)  # need an actual array and not a view
    u = np.array(u)
    v.resize((3,))
    u.resize((3,))
    vx, vy, vz = v
    ux, uy, uz = u
    vout = np.empty((3,))
    st = math.sin(theta)
    ct = math.cos(theta)
    vout[0] = (vx * (ct + ux * ux * (1 - ct)) +
               vy * (ux * uy * (1 - ct) - uz * st) +
               vz * (ux * uz * (1 - ct) + uy * st))
    vout[1] = (vx * (uy * ux * (1 - ct) + uz * st) +
               vy * (ct + uy * uy * (1 - ct)) +
               vz * (uy * uz * (1 - ct) - ux * st))
    vout[2] = (vx * (uz * ux * (1 - ct) - uy * st) +
               vy * (uz * uy * (1 - ct) + ux * st) +
               vz * (ct + uz * uz * (1 - ct)))
    return vout


def quatrot(a, b):
    """Apply a rotation quaternion.

    Args:
        b (:class:`numpy.ndarray`): Vector to be rotated.
        a (:class:`numpy.ndarray`): Rotation quaternion.
    """
    s = a[0]
    v = a[1:4]
    return ((s * s - np.dot(v, v)) * b +
            2 * s * np.cross(v, b) +
            2 * np.dot(v, b) * v)


class Constraint:
    """Constraint base class.

    Base class for constraints on vectors to define the API. All constraints
    should have a 'radius' defining a bounding sphere and a 'satisfies' method
    to determine whether an input vector satisfies the constraint.
    """

    def __init__(self, R, *args, **kwargs):
        """Constructor.

        R (float): Required parameter describes the circumsphere of influence
            of the constraint for quick tests.
        """
        self.radius = R

    def satisfies(self, v):
        """Constraint test.

        Args:
            v ((3) :class:`numpy.ndarray`): Vector to test against constraint.
        """
        return True


class AlignedBoxConstraint(Constraint):
    """Axis-aligned Box constraint.

    Tetragonal box aligned with the coordinate system. Consider using a small z
    dimension to serve as a plane plus or minus some epsilon. Set R < L for a
    cylinder.

    """

    def __init__(self, R, *args, **kwargs):
        """Constructor.

        Args:
            R (float): Required parameter describes the circumsphere of
                influence of the constraint for quick tests.
        """
        self.radius = R
        self.R2 = R * R
        [self.xneg, self.xpos,
         self.yneg, self.ypos,
         self.zneg, self.zpos] = args

    def satisfies(self, v):
        """Constraint test.

        Args:
            v ((3) :class:`numpy.ndarray`): Vector to test against constraint.
        """
        satisfied = False
        if np.dot(v, v) <= self.R2:
            if v[0] >= self.xneg and v[0] <= self.xpos:
                if v[1] >= self.yneg and v[1] <= self.ypos:
                    if v[2] >= self.zneg and v[2] <= self.zpos:
                        satisfied = True
        return satisfied


def constrainedLatticePoints(v1, v2, v3, constraint):
    """Generate a list of points satisfying a constraint.

    Args:
        v1 (:class:`numpy.ndarray`): Lattice vector 1 along which to test.
        v2 (:class:`numpy.ndarray`): Lattice vector 2 along which to test.
        v3 (:class:`numpy.ndarray`): Lattice vector 3 along which to test.
        constraint (:py:class:`Constraint`): Constraint object to test lattice
            points against.
    """
    # Find shortest distance, G, possible with lattice vectors
    # See how many G, nmax, fit in bounding box radius R
    # Limit indices h, k, l to [-nmax, nmax]
    # Check each value h, k, l to see if vector satisfies constraint
    # Return list of vectors
    R = constraint.radius
    # Find shortest distance G. Assume lattice reduction is not necessary.
    gvec = v1 + v2 + v3
    G2 = np.dot(gvec, gvec)
    # This potentially checks redundant vectors, but optimization might require
    # hard-to-unroll loops.
    for h in [-1, 0, 1]:
        for k in [-1, 0, 1]:
            for l in [-1, 0, 1]:
                if [h, k, l] == [0, 0, 0]:
                    continue
                newvec = h * v1 + k * v2 + l * v3
                mag2 = np.dot(newvec, newvec)
                if mag2 < G2:
                    gvec = newvec
                    G2 = mag2
    G = np.sqrt(G2)
    nmax = int((R / G) + 1)
    # Check each point against constraint
    # This potentially checks redundant vectors but we don't want to assume
    # anything about the constraint.
    vec_list = list()
    for h in range(-nmax, nmax + 1):
        for k in range(-nmax, nmax + 1):
            for l in range(-nmax, nmax + 1):
                gvec = h * v1 + k * v2 + l * v3
                if constraint.satisfies(gvec):
                    vec_list.append(gvec)
    length = len(vec_list)
    vec_array = np.empty((length, 3), dtype=np.float32)
    if length > 0:
        vec_array[...] = vec_list
    return vec_array


def reciprocalLattice3D(a1, a2, a3):
    """Calculate reciprocal lattice vectors.

    3D reciprocal lattice vectors with magnitude equal to angular wave number.

    Args:
        a1 (:class:`numpy.ndarray`): Real space lattice vector 1.
        a2 (:class:`numpy.ndarray`): Real space lattice vector 2.
        a3 (:class:`numpy.ndarray`): real space lattice vector 3.

    Returns:
        list: Reciprocal space vectors.

    .. note::
        For unit test, :code:`dot(g[i], a[j]) = 2 * pi * diracDelta(i, j)`:
            list of reciprocal lattice vectors
    """
    a1 = np.asarray(a1)
    a2 = np.asarray(a2)
    a3 = np.asarray(a3)
    a2xa3 = np.cross(a2, a3)
    g1 = (2 * np.pi / np.dot(a1, a2xa3)) * a2xa3
    a3xa1 = np.cross(a3, a1)
    g2 = (2 * np.pi / np.dot(a2, a3xa1)) * a3xa1
    a1xa2 = np.cross(a1, a2)
    g3 = (2 * np.pi / np.dot(a3, a1xa2)) * a1xa2
    return g1, g2, g3


class DeltaSpot:
    """Base class for drawing diffraction spots on a 2D grid.

    Based on the dimensions of a grid, determines which grid points need to be
    modified to represent a diffraction spot and generates the values in that
    subgrid. Spot is a single pixel at the closest grid point.

    Args:
        shape ((2) :class:`numpy.ndarray`):
            Number of grid points in each dimension.
        extent ((2) :class:`numpy.ndarray`):
            Range of x,y values associated with grid points.
    """

    def __init__(self, shape, extent, *args, **kwargs):
        self.shape = shape
        self.extent = extent
        self.dx = np.float32(extent[1] - extent[0]) / (shape[0] - 1)
        self.dy = np.float32(extent[3] - extent[2]) / (shape[1] - 1)
        self.x, self.y = np.float32(0), np.float32(0)

    def set_xy(self, x, y):
        """Set :math:`x`, :math:`y` values of spot center.

        Args:
            x (float):
                x value of spot center.
            y (float):
                y value of spot center.
        """
        self.x, self.y = np.float32(x), np.float32(y)
        # round to nearest grid point
        i = int(np.round((self.x - self.extent[0]) / self.dx))
        j = int(np.round((self.y - self.extent[2]) / self.dy))
        self.gridPoints = i, j

    def get_gridPoints(self):
        """Get indices of sub-grid.

        Based on the type of spot and its center, return the grid mask of
        points containing the spot.
        """
        return self.gridPoints

    def makeSpot(self, cval):
        """Generate intensity value(s) at sub-grid points.

        Args:
            cval (:class:`numpy.complex64`):
                Complex valued amplitude used to generate spot intensity.
        """
        return (np.conj(cval) * cval).real


class GaussianSpot(DeltaSpot):
    """Draw diffraction spot as a Gaussian blur.

    Grid points filled according to Gaussian at spot center.

    Args:
        shape ((2) :class:`numpy.ndarray`):
            Number of grid points in each dimension.
        extent ((2) :class:`numpy.ndarray`):
            Range of x, y values associated with grid points.
    """

    def __init__(self, shape, extent, *args, **kwargs):
        """Constructor.

        """
        DeltaSpot.__init__(self, shape, extent, *args, **kwargs)
        if 'sigma' in kwargs:
            self.set_sigma(kwargs['sigma'])
        else:
            self.set_sigma(self.dx)
        self.set_xy(0, 0)

    def set_xy(self, x, y):
        """Set :math:`x`, :math:`y` values of spot center.

        Args:
            x (float):
                x value of spot center.
            y (float):
                y value of spot center.
        """
        self.x, self.y = np.float32(x), np.float32(y)
        # set grid: two index matrices of i and j values
        nx = int((3. * self.sigma / self.dx) + 1)
        ny = int((3. * self.sigma / self.dy) + 1)
        shape = (2 * nx + 1, 2 * ny + 1)
        gridx, gridy = np.indices(shape)
        # round center to nearest grid point
        i = int(np.round((self.x - self.extent[0]) / self.dx))
        j = int(np.round((self.y - self.extent[2]) / self.dy))
        gridx += i - nx
        gridy += j - ny
        # calculate x, y coordinates at grid points
        self.xvals = np.asarray(
            gridx * self.dx + self.extent[0], dtype=np.float32)
        self.yvals = np.asarray(
            gridy * self.dy + self.extent[2], dtype=np.float32)
        # remove values outside of extent
        mask = (self.xvals >= self.extent[0]) \
            * (self.xvals <= self.extent[1]) \
            * (self.yvals >= self.extent[2]) \
            * (self.yvals <= self.extent[3])
        self.gridPoints = np.array([gridx[mask], gridy[mask]])
        self.xvals = self.xvals[mask]
        self.yvals = self.yvals[mask]

    def makeSpot(self, cval):
        """Generate intensity value(s) at sub-grid points.

        Args:
            cval (:class:`numpy.complex64`):
                Complex valued amplitude used to generate spot intensity.
        """
        val = (np.conj(cval) * cval).real
        # calculate gaussian at grid points and multiply by val
        # currently assume "circular" gaussian: sigma_x = sigma_y
        # Precalculate gaussian argument
        x = self.xvals - self.x
        y = self.yvals - self.y
        gaussian = np.exp((-x * x - y * y) / (self.ss2))
        return val * gaussian

    def set_sigma(self, sigma):
        """Define Gaussian.

        Args:
            sigma (float): Width of the Gaussian spot.
        """
        self.sigma = np.float32(sigma)
        self.ss2 = np.float32(sigma * sigma * 2)