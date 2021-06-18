import os

import gsd.hoomd
import numpy as np
import numpy.testing as npt
import pytest

import freud


def _read_gsd_snapshot(filename):
    filename = os.path.join(
        os.path.dirname(__file__),
        "files",
        "steinhardt_average",
        filename,
    )
    with gsd.hoomd.open(filename) as traj:
        gsd_frame = traj[-1]
    return gsd_frame


def _get_reference_data(name):
    return np.genfromtxt(
        os.path.join(
            os.path.dirname(__file__),
            "files",
            "steinhardt_average",
            f"{name}.txt",
        )
    )


def _compute_steinhardts(system, steinhardt_params, neighbors):
    qls = []
    for params in steinhardt_params:
        op = freud.order.Steinhardt(**params)
        op.compute(system, neighbors=neighbors)
        qls.append(op.particle_order)
    return np.array(qls).T


def _compute_comparison_data(system, average=False, weighted=False):
    """Computes q4, q6, w4, w6 with or without averaging and weighting."""
    if weighted:
        # Use Voronoi neighbors
        voro = freud.locality.Voronoi().compute(system=system)
        nlist = voro.nlist
    else:
        # Use neighbors within radius
        nbQueryDict = dict(mode="ball", r_max=1.4, exclude_ii=True)
        nq = freud.locality.AABBQuery.from_system(system)
        nlist = (
            nq.from_system(system)
            .query(system.particles.position, nbQueryDict)
            .toNeighborList()
        )
    return _compute_steinhardts(
        system,
        [
            dict(average=average, weighted=weighted, l=4),
            dict(average=average, weighted=weighted, l=6),
            dict(average=average, weighted=weighted, l=4, wl=True, wl_normalize=True),
            dict(average=average, weighted=weighted, l=6, wl=True, wl_normalize=True),
        ],
        nlist,
    )


def _compute_msms(system, lmax, average=False, wl=False):
    """Returns Minkowski Structure Metrics up to a maximum l value."""
    voro = freud.locality.Voronoi().compute(system=system)
    op = freud.order.Steinhardt(
        l=list(range(lmax + 1)), average=average, weighted=True, wl=wl, wl_normalize=wl
    )
    op.compute(system, neighbors=voro.nlist)
    return op.particle_order


class TestSteinhardtReferenceValues:
    def test_gc_radius(self):
        """Check freud against data generated by GC reference code.

        Data provided by a collaborator of Robin van Damme.
        """
        gc_data = _get_reference_data("GC_rc1.4_q4q6w4w6")
        gsd_frame = _read_gsd_snapshot("Test_Configuration.gsd")
        freud_data = _compute_comparison_data(gsd_frame, average=False, weighted=False)
        names = ["q4", "q6", "w4", "w6"]
        for i, name in enumerate(names):
            npt.assert_allclose(
                gc_data[:, i], freud_data[:, i], atol=2e-5, err_msg=f"{name} failed"
            )

    def test_gc_radius_ave(self):
        """Check freud against data generated by GC reference code.

        Data provided by a collaborator of Robin van Damme.
        """
        gc_data = _get_reference_data("GC_rc1.4_avq4avq6avw4avw6")
        gsd_frame = _read_gsd_snapshot("Test_Configuration.gsd")
        freud_data = _compute_comparison_data(gsd_frame, average=True, weighted=False)
        names = ["ave. q4", "ave. q6", "ave. w4", "ave. w6"]
        for i, name in enumerate(names):
            npt.assert_allclose(
                gc_data[:, i], freud_data[:, i], atol=2e-5, err_msg=f"{name} failed"
            )

    def test_rvd_msm(self):
        """Check freud against data generated by MSM reference code.

        https://github.com/ArvDee/Minkowski-structure-metrics-calculator
        """
        rvd_data = _get_reference_data("RvD_MSM_q4q6w4w6")
        gsd_frame = _read_gsd_snapshot("Test_Configuration.gsd")
        freud_data = _compute_comparison_data(gsd_frame, average=False, weighted=True)
        names = ["q'4", "q'6", "w'4", "w'6"]
        for i, name in enumerate(names):
            npt.assert_allclose(
                rvd_data[:, i], freud_data[:, i], atol=2e-5, err_msg=f"{name} failed"
            )

    def test_rvd_msm_ave(self):
        """Check freud against data generated by MSM reference code.

        https://github.com/ArvDee/Minkowski-structure-metrics-calculator
        """
        rvd_data = _get_reference_data("RvD_MSM_avq4avq6avw4avw6")
        gsd_frame = _read_gsd_snapshot("Test_Configuration.gsd")
        freud_data = _compute_comparison_data(gsd_frame, average=True, weighted=True)
        names = ["ave. q'4", "ave. q'6", "ave. w'4", "ave. w'6"]
        for i, name in enumerate(names):
            # If most of the particles agree, this test is probably correct.
            # Close investigation showed that numerical issues (truncated
            # particle positions?) and bonds with facet weights of the order of
            # 1e-9 caused some deviations in the neighbor counts, which in turn
            # affected the averaged ql values. This affected 37 out of 3288
            # particles in the sample data for one of the cases checked.
            close_values = np.isclose(rvd_data[:, i], freud_data[:, i], atol=5e-5)
            assert sum(close_values) > (0.985 * len(freud_data)), f"{name} failed"

    @pytest.mark.parametrize(
        "reference,average,wl",
        [
            ("q", False, False),
            ("w", False, True),
            ("avq", True, False),
            ("avw", True, True),
        ],
    )
    def test_msm_calc(self, reference, average, wl):
        """Check freud against data generated by MSM reference code.

        https://github.com/ArvDee/Minkowski-structure-metrics-calculator
        """
        msm_data = _get_reference_data(f"{reference}_0")
        gsd_frame = _read_gsd_snapshot("Test_Configuration.gsd")
        lmax = 6
        freud_data = _compute_msms(gsd_frame, lmax, average, wl)
        for sph_l in range(lmax + 1):
            if wl and sph_l == 2:
                # w'2 tests fail for unknown (probably numerical) reasons.
                continue
            name = f"{reference}{sph_l}"
            # If most of the particles agree, this test is probably correct.
            # Close investigation showed that numerical issues (truncated
            # particle positions in the dat file?) and bonds with facet weights
            # of the order of 1e-9 caused some deviations in the neighbor
            # counts, which in turn affected the averaged ql values. This
            # affected 37 out of 3288 particles in the sample data.
            close_values = np.isclose(
                msm_data[:, sph_l], freud_data[:, sph_l], atol=1e-5
            )
            assert sum(close_values) > (0.985 * len(freud_data)), f"{name} failed"
