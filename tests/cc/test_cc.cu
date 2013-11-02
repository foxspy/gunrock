// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * test_cc.cu
 *
 * @brief Simple test driver program for CC.
 */

#include <stdio.h> 
#include <string>
#include <deque>
#include <vector>
#include <iostream>

// Utilities and correctness-checking
#include <gunrock/util/test_utils.cuh>

// Graph construction utils
#include <gunrock/graphio/market.cuh>

// CC includes
#include <gunrock/app/cc/cc_enactor.cuh>
#include <gunrock/app/cc/cc_problem.cuh>
#include <gunrock/app/cc/cc_functor.cuh>

// Operator includes
#include <gunrock/oprtr/vertex_map/kernel.cuh>

// Boost includes for CPU CC reference algorithms
#include <boost/config.hpp>
#include <boost/graph/adjacency_list.hpp>
#include <boost/graph/connected_components.hpp>

using namespace gunrock;
using namespace gunrock::util;
using namespace gunrock::oprtr;
using namespace gunrock::app::cc;


/******************************************************************************
 * Defines, constants, globals 
 ******************************************************************************/

bool g_verbose;
bool g_undirected;
bool g_quick;
bool g_stream_from_host;

template <typename VertexId>
struct CcList {
    VertexId        root;
    unsigned int    histogram;

    CcList(VertexId root, unsigned int histogram) : root(root), histogram(histogram) {}
};

template<typename CcList>
bool CCCompare(
    CcList elem1,
    CcList elem2)
{
    return elem1.histogram > elem2.histogram;
}


/******************************************************************************
 * Housekeeping Routines
 ******************************************************************************/
 void Usage()
 {
 printf("\ntest_cc <graph type> <graph type args> [--device=<device_index>] "
        "[--instrumented] [--quick] [--num_gpus=<gpu number>]\n"
        "\n"
        "Graph types and args:\n"
        "  market [<file>]\n"
        "    Reads a Matrix-Market coordinate-formatted graph of directed/undirected\n"
        "    edges from stdin (or from the optionally-specified file).\n"
        );
 }

 /**
  * Displays the CC result (i.e., number of components)
  */
 template<typename VertexId, typename SizeT>
 void DisplaySolution(VertexId *comp_ids, SizeT nodes, unsigned int num_components, VertexId *roots, unsigned int *histogram)
 {
    typedef CcList<VertexId> CcListType;
    printf("Number of components: %d\n", num_components);

    if (nodes <= 40) {
        printf("[");
        for (VertexId i = 0; i < nodes; ++i) {
            PrintValue(i);
            printf(":");
            PrintValue(comp_ids[i]);
            printf(",");
            printf(" ");
        }
        printf("]\n");
    }
    else {
        //sort the components by size
        CcListType *cclist = (CcListType*)malloc(sizeof(CcListType) * num_components);
        for (int i = 0; i < num_components; ++i)
        {
            cclist[i].root = roots[i];
            cclist[i].histogram = histogram[i];
        }
        std::stable_sort(cclist, cclist + num_components, CCCompare<CcListType>);

        // Print out at most top 10 largest components
        int top = (num_components < 10) ? num_components : 10;
        printf("Top %d largest components:\n", top);
        for (int i = 0; i < top; ++i)
        {
            printf("CC ID: %d, CC Root: %d, CC Size: %d\n", i, cclist[i].root, cclist[i].histogram);
        }
    }
 }

 /**
  * Performance/Evaluation statistics
  */

 struct Statistic
 {
    double mean;
    double m2;
    int count;

    Statistic() : mean(0.0), m2(0.0), count(0) {}

    /**
     * Updates running statistic, returning bias-corrected sample variance.
     * Online method as per Knuth.
     */
    double Update(double sample)
    {
        count++;
        double delta = sample - mean;
        mean = mean + (delta / count);
        m2 = m2 + (delta * (sample - mean));
        return m2 / (count - 1);                //bias-corrected
    }
};

/******************************************************************************
 * CC Testing Routines
 *****************************************************************************/

/**
 * CPU-based reference CC algorithm using Boost Graph Library
 */
template<typename VertexId, typename SizeT>
unsigned int RefCPUCC(SizeT *row_offsets, VertexId *column_indices, int num_nodes, int *labels)
{
    using namespace boost;
    typedef adjacency_list <vecS, vecS, undirectedS> Graph;
    Graph G;
    for (int i = 0; i < num_nodes; ++i)
    {
        for (int j = row_offsets[i]; j < row_offsets[i+1]; ++j)
        {
            add_edge(i, column_indices[j], G);
        }
    }
    CpuTimer cpu_timer;
    cpu_timer.Start();
    int num_components = connected_components(G, &labels[0]);
    cpu_timer.Stop();
    float elapsed = cpu_timer.ElapsedMillis();
    printf("CPU CC finished in %lf msec.\n", elapsed);
    return num_components;
}

/**
 * Run tests
 */
template <
    typename VertexId,
    typename Value,
    typename SizeT,
    bool INSTRUMENT>
void RunTests(
    const Csr<VertexId, Value, SizeT> &graph,
    int max_grid_size,
    int num_gpus)
{
    typedef CCProblem<
        VertexId,
        SizeT,
        Value,
        io::ld::cg,
        io::ld::NONE,
        io::ld::NONE,
        io::ld::cg,
        io::ld::NONE,
        io::st::cg,
        true> Problem; //use double buffer for edgemap and vertexmap.

    typedef UpdateMaskFunctor<
        VertexId,
        SizeT,
        Value,
        Problem> UpdateMaskFunctor;

    typedef HookMinFunctor<
        VertexId,
        SizeT,
        Value,
        Problem> HookMinFunctor;
    
    typedef HookMaxFunctor<
        VertexId,
        SizeT,
        Value,
        Problem> HookMaxFunctor;

    typedef PtrJumpFunctor<
        VertexId,
        SizeT,
        Value,
        Problem> PtrJumpFunctor;

    typedef PtrJumpMaskFunctor<
        VertexId,
        SizeT,
        Value,
        Problem> PtrJumpMaskFunctor;

    typedef PtrJumpUnmaskFunctor<
        VertexId,
        SizeT,
        Value,
        Problem> PtrJumpUnmaskFunctor;


        // Allocate host-side label array (for both reference and gpu-computed results)
        VertexId    *reference_component_ids        = (VertexId*)malloc(sizeof(VertexId) * graph.nodes);
        VertexId    *h_component_ids                = (VertexId*)malloc(sizeof(VertexId) * graph.nodes);
        VertexId    *reference_check                = (g_quick) ? NULL : reference_component_ids;
        unsigned int ref_num_components             = 0;

        // Allocate CC enactor map
        CCEnactor<INSTRUMENT> cc_enactor(g_verbose);

        // Allocate problem on GPU
        Problem *csr_problem = new Problem;
        if (csr_problem->Init(
            g_stream_from_host,
            graph.nodes,
            graph.edges,
            graph.row_offsets,
            graph.column_indices,
            num_gpus)) exit(1);

        //
        // Compute reference CPU BFS solution for source-distance
        //
        if (reference_check != NULL)
        {
            printf("compute ref value\n");
            ref_num_components = RefCPUCC(
                    graph.row_offsets,
                    graph.column_indices,
                    graph.nodes,
                    reference_check);
            printf("\n");
        }

        cudaError_t         retval = cudaSuccess;

        // Perform CC
        GpuTimer gpu_timer;

        if (retval = csr_problem->Reset(cc_enactor.GetFrontierType(), 1.0)) exit(1);
        gpu_timer.Start();
        if (retval = cc_enactor.template Enact<Problem,
                                            UpdateMaskFunctor,
                                            HookMinFunctor,
                                            HookMaxFunctor,
                                            PtrJumpFunctor,
                                            PtrJumpMaskFunctor,
                                            PtrJumpUnmaskFunctor>(csr_problem, max_grid_size)) exit(1);
        gpu_timer.Stop();

        if (retval && (retval != cudaErrorInvalidDeviceFunction)) {
            exit(1);
        }

        float elapsed = gpu_timer.ElapsedMillis();

        // Copy out results
        if (csr_problem->Extract(h_component_ids)) exit(1);

        // Validity
        if (ref_num_components == csr_problem->num_components)
            printf("CORRECT.\n");
        else
            printf("INCORRECT. Ref Component Count: %d, GPU Computed Component Count: %d\n", ref_num_components, csr_problem->num_components);

        if (ref_num_components == csr_problem->num_components)
        {
            // Compute size and root of each component
            VertexId        *h_roots            = new VertexId[csr_problem->num_components];
            unsigned int    *h_histograms       = new unsigned int[csr_problem->num_components];

            csr_problem->ComputeDetails(h_component_ids, h_roots, h_histograms);

            // Display Solution
            //VertexId *comp_ids, SizeT nodes, unsigned int num_components, VertexId *roots, unsigned int *histogram
            DisplaySolution(h_component_ids, graph.nodes, ref_num_components, h_roots, h_histograms);
        }

        printf("GPU Connected Component finished in %lf msec.\n", elapsed);

        // Cleanup
        if (csr_problem) delete csr_problem;
        if (reference_component_ids) free(reference_component_ids);
        if (h_component_ids) free(h_component_ids);

        cudaDeviceSynchronize();
}

template <
    typename VertexId,
    typename Value,
    typename SizeT>
void RunTests(
    Csr<VertexId, Value, SizeT> &graph,
    CommandLineArgs &args)
{
    bool                instrumented        = false;        // Whether or not to collect instrumentation from kernels
    int                 max_grid_size       = 0;            // maximum grid size (0: leave it up to the enactor)
    int                 num_gpus            = 1;            // Number of GPUs for multi-gpu enactor to use

    instrumented = args.CheckCmdLineFlag("instrumented");

    g_quick = args.CheckCmdLineFlag("quick");
    args.GetCmdLineArgument("num-gpus", num_gpus);
    g_verbose = args.CheckCmdLineFlag("v");

    if (instrumented) {
            RunTests<VertexId, Value, SizeT, true>(
                graph,
                max_grid_size,
                num_gpus);
    } else {
            RunTests<VertexId, Value, SizeT, false>(
                graph,
                max_grid_size,
                num_gpus);
    }
}



/******************************************************************************
 * Main
 ******************************************************************************/

int main( int argc, char** argv)
{
	CommandLineArgs args(argc, argv);

	if ((argc < 2) || (args.CheckCmdLineFlag("help"))) {
		Usage();
		return 1;
	}

	DeviceInit(args);
	cudaSetDeviceFlags(cudaDeviceMapHost);

	//srand(0);									// Presently deterministic
	//srand(time(NULL));

	// Parse graph-contruction params
	g_undirected = false; //Does not make undirected graph

	std::string graph_type = argv[1];
	int flags = args.ParsedArgc();
	int graph_args = argc - flags - 1;

	if (graph_args < 1) {
		Usage();
		return 1;
	}
	
	//
	// Construct graph and perform search(es)
	//

	if (graph_type == "market") {

		// Matrix-market coordinate-formatted graph file

		typedef int VertexId;							// Use as the node identifier type
		typedef int Value;								// Use as the value type
		typedef int SizeT;								// Use as the graph size type
		Csr<VertexId, Value, SizeT> csr(false);         // default value for stream_from_host is false

		if (graph_args < 1) { Usage(); return 1; }
		char *market_filename = (graph_args == 2) ? argv[2] : NULL;
		if (graphio::BuildMarketGraph<false>(
			market_filename, 
			csr, 
			g_undirected) != 0) 
		{
			return 1;
		}

        csr.DisplayGraph();
        fflush(stdout);

		// Run tests
		RunTests(csr, args);

	} else {

		// Unknown graph type
		fprintf(stderr, "Unspecified graph type\n");
		return 1;

	}

	return 0;
}
