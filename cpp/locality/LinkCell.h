#include <boost/shared_array.hpp>
#include <boost/python.hpp>
#include <vector>

#include "trajectory.h"
#include "HOOMDMath.h"
#include "Index1D.h"
#include "num_util.h"

#ifndef _LINKCELL_H__
#define _LINKCELL_H__

namespace freud { namespace locality {

//! Signfies the end of the linked list
const unsigned int LINK_CELL_TERMINATOR = 0xffffffff;

//! Iterates over particles in a link cell list generated by LinkCell
/*! The link-cell structure is not trivial to iterate over. This helper class makes that easier both in c++ and
    provides a python compatibile interface for direct usage there.
    
    An IteratorLinkCell is given the bare essentials it needs to iterate over a given cell, the cell list,
    the number of particles, number of cells and the cell to iterate over. Call next() to get the index of the next 
    particle in the cell, atEnd() will return true if you are at the end. In C++, next() will crash the code if you
    attempt to iterate past the end (no bounds checking for performance). When called from python, a different version
    of next is used that will throw StopIteration at the end.
        
    A loop over all of the particles in a cell can be acomplished with the following code in c++.
\code
 LinkCell::iteratorcell it = lc.itercell(cell);
 for (unsigned int i = it.next(); !it.atEnd(); i=it.next())
    {
    // do something with particle i
    }
\endcode
*/
class IteratorLinkCell
    {
    public:
        IteratorLinkCell(boost::shared_array<unsigned int> cell_list,
                         unsigned int Np,
                         unsigned int Nc,
                         unsigned int cell)
                         : m_cell_list(cell_list), m_Np(Np), m_Nc(Nc)
            {
            assert(cell < Nc);
            assert(Np > 0);
            assert(Nc > 0);
            m_cur_idx = m_Np + cell;
            }
            
        //! Test if the iteration over the cell is complete
        bool atEnd()
            {
            return (m_cur_idx == LINK_CELL_TERMINATOR);
            }
        
        //! Get the next particle index in the list
        unsigned int next()
            {
            m_cur_idx = m_cell_list[m_cur_idx];
            return m_cur_idx;
            }
        
        //! Get the next particle index in the list with python StopIteration
        unsigned int nextPy()
            {
            m_cur_idx = m_cell_list[m_cur_idx];
            
            if (atEnd())
                {
                PyErr_SetNone(PyExc_StopIteration);
                boost::python::throw_error_already_set();
                }
            
            return m_cur_idx;
            }
        
    private:
        boost::shared_array<unsigned int> m_cell_list;    //!< The cell list
        unsigned int m_Np;                                //!< Number of particles in the cell list
        unsigned int m_Nc;                                //!< Number of cells in the cell list
        unsigned int m_cur_idx;                           //!< Current index
    };

//! Computes a cell id for each particle and a link cell data structure for iterating through it
/*! For simplicity in only needing a small number of arrays, the link cell algorithm is used to generate and store 
    the cell list data for particles.
    
    Cells are given a nominal minimum width \a cell_width. Each dimension of the box is split into an integer number of
    cells no smaller than \a cell_width wide in that dimension. The actual number of cells along each dimension is
    stored in an Index3D which is also used to compute the cell index from (i,j,k).
    
    The cell coordinate (i,j,k) itself is computed like so:
    \code
    i = floorf((x + Lx/2) / w) % Nw
    \endcode
    and so on for j,k (y,z). Call getCellCoord to do this computation for an arbitrary point.
    
    <b>Data structures:</b><br>
    The internal data structure used in LinkCell is a linked list of particle indices. See IteratorLinkCell
    for information on how to iterate through these.
    
    <b>2D:</b><br>
    LinkCell properly handles 2D boxes. When a 2D box is handed to LinkCell, it creates an m x n x 1 cell list and
    neighbor cells are only listed in the plane. As with everything else in freud, 2D points must be passed in as
    3 component vectors x,y,0. Failing to set 0 in the third component will lead to undefined behavior.
*/
class LinkCell
    {
    public:
        //! iterator to iterate over particles in the cell
        typedef IteratorLinkCell iteratorcell;
    
        //! Constructor
        LinkCell(const trajectory::Box& box, float cell_width);
        
        //! Get the simulation box
        const trajectory::Box& getBox() const
            {
            return m_box;
            }
        
        //! Get the cell indexer
        const Index3D& getCellIndexer() const
            {
            return m_cell_index;
            }
        
        //! Get the number of cells
        unsigned int getNumCells() const
            {
            return m_cell_index.getNumElements();
            }
        
        //! Compute the cell id for a given position
        unsigned int getCell(const float3& p) const
            {
            uint3 c = getCellCoord(p);
            return m_cell_index(c.x, c.y, c.z);
            }
        
        //! Wrapper for python to getCell
        unsigned int getCellPy(boost::python::numeric::array p)
            {
            // validate input type and rank
            num_util::check_type(p, PyArray_FLOAT);
            num_util::check_rank(p, 1);
            
            // validate that the 2nd dimension is only 3
            num_util::check_size(p, 3);
            
            // get the raw data pointers and compute the cell index
            float3* p_raw = (float3*) num_util::data(p);
            return getCell(*p_raw);
            }
            
        //! Compute cell coordinates for a given position
        uint3 getCellCoord(const float3& p) const
            {
            float3 alpha = m_box.makeunit(p);
            uint3 c;
            c.x = floorf(alpha.x * float(m_cell_index.getW()));
            c.x %= m_cell_index.getW();
            c.y = floorf(alpha.y * float(m_cell_index.getH()));
            c.y %= m_cell_index.getH();
            c.z = floorf(alpha.z * float(m_cell_index.getD()));
            c.z %= m_cell_index.getD();
            return c;
            }
        
        //! Iterate over particles in a cell
        iteratorcell itercell(unsigned int cell) const
            {
            assert(m_cell_list.get() != NULL);
            return iteratorcell(m_cell_list, m_Np, getNumCells(), cell);
            }
        
        //! Get a list of neighbors to a cell
        const std::vector<unsigned int>& getCellNeighbors(unsigned int cell) const
            {
            return m_cell_neighbors[cell];
            }
        
        //! Python wrapper for getCellNeighbors
        boost::python::numeric::array getCellNeighborsPy(unsigned int cell)
            {
            unsigned int *start = &m_cell_neighbors[cell][0];
            return num_util::makeNum(start, m_cell_neighbors[cell].size());
            }
        
        //! Compute the cell list
        void computeCellList(const float3 *points, unsigned int Np);
        
        //! Python wrapper for computeCellList
        void computeCellListPy(boost::python::numeric::array points);
    private:
        trajectory::Box m_box;      //!< Simulation box the particles belong in
        Index3D m_cell_index;       //!< Indexer to compute cell indices
        unsigned int m_Np;          //!< Number of particles last placed into the cell list
        
        boost::shared_array<unsigned int> m_cell_list;    //!< The cell list last computed
        
        std::vector< std::vector<unsigned int> > m_cell_neighbors;    //!< List of cell neighborts to each cell
        
        //! Helper function to compute cell neighbors
        void computeCellNeighbors();
    };

//! Exports all classes in this file to python
void export_LinkCell();

}; }; // end namespace freud::locality

#endif // _LINKCELL_H__
