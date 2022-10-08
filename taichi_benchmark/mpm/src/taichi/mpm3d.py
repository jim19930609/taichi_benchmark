import numpy as np
import taichi as ti
from time import perf_counter

# Benchmark MPM 3D
# dim, steps, dt = 3, 25, 8e-5


def run_mpm(n_grid=32, nIters=2048):
    ti.init(arch=ti.gpu, device_memory_GB=4)

    dim, steps, dt = 3, 25, 8e-5

    n_particles = n_grid**dim // 2**(dim - 1)
    dx = 1 / n_grid

    p_rho = 1
    p_vol = (dx * 0.5)**2
    p_mass = p_vol * p_rho
    gravity = 9.8
    bound = 3
    E = 400

    x = ti.Vector.field(dim, float, n_particles)
    v = ti.Vector.field(dim, float, n_particles)
    C = ti.Matrix.field(dim, dim, float, n_particles)
    J = ti.field(float, n_particles)

    grid_v = ti.Vector.field(dim, float, (n_grid, ) * dim)
    grid_m = ti.field(float, (n_grid, ) * dim)

    neighbour = (3, ) * dim

    @ti.kernel
    def substep():
        for I in ti.grouped(grid_m):
            grid_v[I] = ti.zero(grid_v[I])
            grid_m[I] = 0

        ti.loop_config(block_dim = 64)
        for p in x:
            Xp = x[p] / dx
            base = int(Xp - 0.5)
            fx = Xp - base
            w = [0.5 * (1.5 - fx)**2, 0.75 - (fx - 1)**2, 0.5 * (fx - 0.5)**2]
            stress = -dt * 4 * E * p_vol * (J[p] - 1) / dx**2
            affine = ti.Matrix.identity(float, dim) * stress + p_mass * C[p]
            for offset in ti.static(ti.grouped(ti.ndrange(*neighbour))):
                dpos = (offset - fx) * dx
                weight = 1.0
                for i in ti.static(range(dim)):
                    weight *= w[offset[i]][i]
                grid_v[base +
                       offset] += weight * (p_mass * v[p] + affine @ dpos)
                grid_m[base + offset] += weight * p_mass
        for I in ti.grouped(grid_m):
            if grid_m[I] > 0:
                grid_v[I] /= grid_m[I]
            grid_v[I][1] -= dt * gravity
            cond = (I < bound) & (grid_v[I] < 0) | \
                   (I > n_grid - bound) & (grid_v[I] > 0)
            grid_v[I] = 0 if cond else grid_v[I]

        ti.loop_config(block_dim = 64)
        for p in x:
            Xp = x[p] / dx
            base = int(Xp - 0.5)
            fx = Xp - base
            w = [0.5 * (1.5 - fx)**2, 0.75 - (fx - 1)**2, 0.5 * (fx - 0.5)**2]
            new_v = ti.zero(v[p])
            new_C = ti.zero(C[p])
            for offset in ti.static(ti.grouped(ti.ndrange(*neighbour))):
                dpos = (offset - fx) * dx
                weight = 1.0
                for i in ti.static(range(dim)):
                    weight *= w[offset[i]][i]
                g_v = grid_v[base + offset]
                new_v += weight * g_v
                new_C += 4 * weight * g_v.outer_product(dpos) / dx**2
            v[p] = new_v
            x[p] += dt * v[p]
            J[p] *= 1 + dt * new_C.trace()
            C[p] = new_C

    @ti.kernel
    def init():
        for i in range(n_particles):
            x[i] = ti.Vector([ti.random() for i in range(dim)]) * 0.4 + 0.15
            J[i] = 1

    def T(a):
        if dim == 2:
            return a

        phi, theta = np.radians(28), np.radians(32)

        a = a - 0.5
        x, y, z = a[:, 0], a[:, 1], a[:, 2]
        c, s = np.cos(phi), np.sin(phi)
        C, S = np.cos(theta), np.sin(theta)
        x, z = x * c + z * s, z * c - x * s
        u, v = x, y * C + z * S
        return np.array([u, v]).swapaxes(0, 1) + 0.5

    def run():
        # skip first run
        init()
        for s in range(steps):
            substep()
        pos = x.to_numpy()
        # measure
        t_start = perf_counter()
        for _ in range(nIters):
            for s in range(steps):
                substep()
            pos = x.to_numpy()
            ti.sync()
        t_stop = perf_counter()
        return {
            'n_particles': n_particles,
            'time_ms': (t_stop - t_start) * 1000 / nIters
        }

    return run()


if __name__ == '__main__':
    n_grid = 32
    for _ in range(5):
        result = run_mpm(n_grid)
        n_particles = result['n_particles']
        time_ms = result['time_ms']
        print("{} particles run {:.3f} time_ms".format(n_particles, time_ms))
