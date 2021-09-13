// Copyright (c) 2010-2020 The Regents of the University of Michigan
// This file is from the freud project, released under the BSD 3-Clause License.

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

#include "Box.h"
#include "ManagedArray.h"
#include "NeighborComputeFunctional.h"
#include "NeighborQuery.h"
#include "RDF.h"
#include "StaticStructureFactorDebye.h"
#include "utils.h"

/*! \file StaticStructureFactorDebye.cc
    \brief Routines for computing static structure factors.
*/

namespace freud { namespace diffraction {

StaticStructureFactorDebye::StaticStructureFactorDebye(unsigned int bins, float k_max, float k_min)
{
    if (bins == 0)
    {
        throw std::invalid_argument("StaticStructureFactorDebye requires a nonzero number of bins.");
    }
    if (k_max <= 0)
    {
        throw std::invalid_argument("StaticStructureFactorDebye requires k_max to be positive.");
    }
    if (k_min < 0)
    {
        throw std::invalid_argument("StaticStructureFactorDebye requires k_min to be non-negative.");
    }
    if (k_max <= k_min)
    {
        throw std::invalid_argument("StaticStructureFactorDebye requires that k_max must be greater than k_min.");
    }

    // Construct the Histogram object that will be used to track the structure factor
    auto axes
        = S_kHistogram::Axes {std::make_shared<util::RegularAxis>(bins, k_min, k_max)};
    m_histogram = S_kHistogram(axes);
    m_local_histograms = S_kHistogram::ThreadLocalHistogram(m_histogram);
    m_min_valid_k = std::numeric_limits<float>::infinity();
    m_structure_factor.prepare(bins);
}

void StaticStructureFactorDebye::accumulate(const freud::locality::NeighborQuery* neighbor_query,
                                             const vec3<float>* query_points, unsigned int n_query_points, unsigned int n_total)
{
    auto const& box = neighbor_query->getBox();

    // The r_max should be just less than half of the smallest side length of the box
    auto const box_L = box.getL();
    auto const min_box_length
        = box.is2D() ? std::min(box_L.x, box_L.y) : std::min(box_L.x, std::min(box_L.y, box_L.z));
    auto const r_max = std::nextafter(float(0.5) * min_box_length, float(0));
    auto const points= neighbor_query->getPoints();
    auto const n_points= neighbor_query->getNPoints();

    // The minimum k value of validity is 4 * pi / L, where L is the smallest side length.
    // This is equal to 2 * pi / r_max.
    m_min_valid_k = std::min(m_min_valid_k, freud::constants::TWO_PI / r_max);

    std::vector<float> distances(n_points * n_query_points);
    box.computeAllDistances(points, n_points, query_points, n_query_points, distances.data());

    auto const k_bin_centers = m_histogram.getBinCenters()[0];

    util::forLoopWrapper(0, m_histogram.getAxisSizes()[0], [&](size_t begin_k_index, size_t end_k_index) {
        for (size_t k_index = begin_k_index; k_index < end_k_index; ++k_index)
        {
            auto const k = k_bin_centers[k_index];
            double S_k = 0.0;
            for (size_t distance_index = 0; distance_index < distances.size(); ++distance_index)
            {
                auto const distance = distances[distance_index];
                S_k += util::sinc(k * distance);
            }
            S_k /= static_cast<double>(n_total);
            m_local_histograms.increment(k_index, S_k);
        };
    });
    m_frame_counter++;
    m_reduce = true;
}

void StaticStructureFactorDebye::reduce()
{
    m_structure_factor.prepare(m_histogram.shape());
    m_local_histograms.reduceInto(m_structure_factor);

    // Normalize by the frame count if necessary
    if (m_frame_counter > 1)
    {
        util::forLoopWrapper(0, m_structure_factor.size(), [&](size_t begin, size_t end) {
            for (size_t i = begin; i < end; ++i)
            {
                m_structure_factor[i] /= static_cast<float>(m_frame_counter);
            }
        });
    }
}

}; }; // namespace freud::diffraction
