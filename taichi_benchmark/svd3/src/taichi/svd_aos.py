import taichi as ti
from time import perf_counter

def SVD(N, nIter=1):
    ti.init(arch=ti.cuda,
        device_memory_fraction=0.9,
        kernel_profiler=True)
    mat = ti.Matrix.field(3, 3, ti.f32, shape=(N,))
    res = ti.Matrix.field(7, 3, ti.f32, shape=(N,))

    @ti.func
    def fill_result_vector(i:ti.i32, U:ti.template(), S:ti.template(), V:ti.template()):
        for x, y in ti.static(ti.ndrange(3, 3)):
            res[i][x, y] = U[x, y]
        # S only needs to save diagonal
        for y in ti.static(range(3)):
            res[i][3, y] = S[y, y]
        for x, y in ti.static(ti.ndrange(3, 3)):
            res[i][4 + x, y] = V[x, y]

    @ti.kernel
    def computeSVD():
        for i in range(N):
            U, S, V = ti.svd(mat[i])
            fill_result_vector(i, U, S, V)

    def benchmark(display_results=False):
        # Warm-up run
        computeSVD()

        # Wall clock
        st = perf_counter()
        # Kernel time
        ti.profiler.clear_kernel_profiler_info()
        for i in range(nIter):
            computeSVD()
        ti.sync()
        # Stop wall clock
        et = perf_counter()
        # Get kernel time
        kernel_time = ti.profiler.get_kernel_profiler_total_time() * 1000.0 / nIter
        wall_time = (et - st) * 1000.0 / nIter
        # Result display
        if display_results:
            print("Kernel average time {}ms".format(kernel_time))
            print("Python scope wall average time {}ms".format(wall_time))
            ti.profiler.print_kernel_profiler_info('trace')
        return {"N":N, "kernel_time": kernel_time, "wall_time":wall_time}

    return benchmark()

if __name__ == '__main__':
    SVD(1048576, 10)
