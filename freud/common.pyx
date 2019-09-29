# Copyright (c) 2010-2019 The Regents of the University of Michigan
# This file is from the freud project, released under the BSD 3-Clause License.

# Methods used throughout freud for convenience

import numpy as np
import freud.box

from functools import wraps

cimport freud.box

cdef class Compute:
    R"""Parent class for all compute classes in freud.

    Currently, the primary purpose of this class is implementing functions to
    prevent access of uncomputed values. This is accomplished by maintaining a
    dictionary of compute functions in a class that have been called and
    decorating class properties with the names of the compute function that
    must be called to populate that property.

    To use this class, one would do, for example,

    .. code-block:: python
        class Cluster(Compute):

            @Compute._compute
            def compute(...)
                ...

            @Compute._computed_property
            def cluster_idx(self):
                return ...

            @Compute._reset
            def reset(...):
                ...

    Attributes:
        _called_compute (dict):
            Flags representing whether appropriate compute method was called.
    """

    def __cinit__(self):
        self._called_compute = False

    @staticmethod
    def _compute(func):
        R"""Decorator that sets compute flag to be true.

        Args:
            func (callable): The compute function.

        Returns:
            Decorator decorating appropriate compute method.
        """

        @wraps(func)
        def wrapper(self, *args, **kwargs):
            retval = func(self, *args, **kwargs)
            self._called_compute = True
            return retval
        return wrapper

    @staticmethod
    def _computed_property(prop):
        R"""Decorator that makes a class method to be a property with limited access.

        Args:
            prop (callable): The property function.

        Returns:
            Decorator decorating appropriate property method.
        """

        @property
        @wraps(prop)
        def wrapper(self, *args, **kwargs):
            if not self._called_compute:
                raise AttributeError(
                    "Property not computed. Call compute first.")
            return prop(self, *args, **kwargs)
        return wrapper

    @staticmethod
    def _computed_method(meth):
        R"""Decorator that makes a class method to be a method with limited access.

        Args:
            meth (callable): The method that requires compute to be called.

        Returns:
            Decorator decorating appropriate method.
        """

        @wraps(meth)
        def wrapper(self, *args, **kwargs):
            if not self._called_compute:
                raise AttributeError(
                    "Property not computed. Call compute first.")
            return meth(self, *args, **kwargs)
        return wrapper

    @staticmethod
    def _reset(func):
        R"""Decorator that sets all compute flag to be false.

        Returns:
            Decorator decorating appropriate reset method.
        """

        @wraps(func)
        def wrapper(self, *args, **kwargs):
            self._called_compute = False
            func(self, *args, **kwargs)
        return wrapper

    def __str__(self):
        return repr(self)


def convert_array(array, shape=None, dtype=np.float32):
    """Function which takes a given array, checks the dimensions and shape,
    and converts to a supplied dtype.

    Args:
        array (:class:`numpy.ndarray`): Array to check and convert.
        shape: (tuple of int and :code:`None`): Expected shape of the array.
            Only the dimensions that are not :code:`None` are checked.
            (Default value = :code:`None`).
        dtype: :code:`dtype` to convert the array to if :code:`array.dtype`
            is different. If :code:`None`, :code:`dtype` will not be changed
            (Default value = :class:`numpy.float32`).

    Returns:
        :class:`numpy.ndarray`: Array.
    """
    array = np.asarray(array)
    return_arr = np.require(array, dtype=dtype, requirements=['C'])
    if shape is not None:
        if array.ndim != len(shape):
            raise ValueError("array.ndim = {}; expected ndim = {}".format(
                return_arr.ndim, len(shape)))

        for i, s in enumerate(shape):
            if s is not None and return_arr.shape[i] != s:
                shape_str = "(" + ", ".join(str(i) if i is not None
                                            else "..." for i in shape) + ")"
                raise ValueError('array.shape= {}; expected shape = {}'.format(
                    return_arr.shape, shape_str))

    return return_arr


def convert_box(box, dimensions=None):
    """Function which takes a box-like object and attempts to convert it to
    :class:`freud.box.Box`. Existing :class:`freud.box.Box` objects are
    used directly.

    Args:
        box (box-like object (see :meth:`freud.box.Box.from_box`)): Box to
            check and convert if needed.
        dimensions (int): Number of dimensions the box should be. If not None,
            used to verify the box dimensions (Default value = :code:`None`).

    Returns:
        :class:`freud.box.Box`: freud box.
    """
    if not isinstance(box, freud.box.Box):
        try:
            box = freud.box.Box.from_box(box)
        except ValueError:
            raise

    if dimensions is not None and box.dimensions != dimensions:
        raise ValueError("The box must be {}-dimensional.".format(dimensions))

    return box
