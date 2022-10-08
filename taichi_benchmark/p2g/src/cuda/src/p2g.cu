#include <chrono>
#include <iostream>
#include <memory>

#include "eigen/Eigen/Dense"
#include "utils.h"

// Benchmark MPM2D
// dim, steps, dt = 2, 32, 1e-4

using Vector = Eigen::Vector2f;
using Matrix = Eigen::Matrix2f;
using Vectori = Eigen::Vector2i;
using Real = float;

// TODO global var
__device__ Real dt = 2e-4;
__device__ Real E = 400;
__device__ int dim = 2;
__device__ int steps = 32;
__device__ int neighbour = 9;
__device__ Real gravity = 9.8;
__device__ int bound = 3;
__device__ Real p_rho = 1.0;

Vector *x_dev;
Vector *v_dev;
Matrix *C_dev;
Real *J_dev;
Vector *grid_v_dev;
Real *grid_m_dev;

__global__ void init_kernel(Real *J) {
  auto idx = blockIdx.x * blockDim.x + threadIdx.x;
  J[idx] = 1;
}

__global__ void reset_kernel(Vector *grid_v, Real *grid_m) {
  auto idx = blockIdx.x * blockDim.x + threadIdx.x;
  grid_v[idx].setZero();
  grid_m[idx] = 0;
}

template <class R, class A> __device__ R narrow_cast(const A &a) {
  R r = R(a);
  if (A(r) != a)
    printf("warning: info loss in narrow_cast\n");
  return r;
}

__device__ Vectori get_offset(size_t idx) {
  Vectori offset;
  for (auto i = dim - 1; i >= 0; i--) {
    offset[i] = narrow_cast<int, size_t>(idx % 3);
    idx /= 3;
  }
  return offset;
}

__device__ Vectori get_indices(size_t idx, int n_grid) {
  Vectori indices;
  for (auto i = dim - 1; i >= 0; i--) {
    indices[i] = narrow_cast<int, size_t>(idx % n_grid);
    idx /= n_grid;
  }
  return indices;
}

__global__ void particle_to_grid_kernel(Vector *x, Vector *v, Matrix *C,
                                        Real *J, Vector *grid_v, Real *grid_m,
                                        Real dx, Real p_vol, Real p_mass,
                                        int n_grid) {
  auto idx = blockIdx.x * blockDim.x + threadIdx.x;
  Vector Xp = x[idx] / dx;
  Vectori base = (Xp.array() - 0.5).cast<int>();
  Vector fx = Xp - base.cast<Real>();
  std::array<Vector, 3> w{0.5 * (1.5 - fx.array()).pow(2),
                          0.75 - (fx.array() - 1.0).pow(2),
                          0.5 * (fx.array() - 0.5).pow(2)};
  auto stress = -dt * 4 * E * p_vol * (J[idx] - 1) / std::pow(dx, 2);
  Matrix affine = Matrix::Identity() * stress + p_mass * C[idx];

  // Vector new_v = Vector::Zero();
  // Matrix new_C = Matrix::Zero();
  for (auto offset_idx = 0; offset_idx < neighbour; offset_idx++) {
    Vectori offset = get_offset(offset_idx);
    Vector dpos = (offset.cast<Real>() - fx) * dx;
    Real weight = 1.0;
    for (auto i = 0; i < dim; i++) {
      weight *= w[offset[i]][i];
    }
    // Vectori grid_idx_vector = base + offset;
    // auto grid_idx = 0;
    // for (auto i = 0; i < dim; i++) {
    //  grid_idx = grid_idx * n_grid + grid_idx_vector[i];
    //}
    // new_v += weight * grid_v[grid_idx];
    // new_C += 4.0 * weight * grid_v[grid_idx] * dpos.transpose() / pow(dx, 2);

    Vectori grid_idx_vector = base + offset;
    auto grid_idx = 0;
    for (auto i = 0; i < dim; i++) {
      grid_idx = grid_idx * n_grid + grid_idx_vector[i];
    }

    // update grid_v
    Vector grid_v_add = weight * (p_mass * v[idx] + affine * dpos);
    for (auto i = 0; i < dim; i++) {
      atomicAdd(&(grid_v[grid_idx][i]), grid_v_add[i]);
    }

    // update grid_m
    auto grid_m_add = weight * p_mass;
    atomicAdd(&(grid_m[grid_idx]), grid_m_add);
  }
  // v[idx] = new_v;
  // x[idx] += dt * v[idx];
  // J[idx] *= Real(1.0) + dt * new_C.trace();
  // C[idx] = new_C;
}

class MPM {
public:
  explicit MPM(int n_grid) : n_grid(n_grid) {
    dim = 2;
    steps = 32;
    n_particles = utils::power(n_grid, dim) / utils::power(2, dim - 1);
    neighbour = utils::power(3, dim);
    dx = 1.0 / n_grid;
    p_rho = 1.0;
    p_vol = utils::power(dx * 0.5, 2);
    p_mass = p_vol * p_rho;
    gravity = 9.8;
    bound = 3;
    E = 400;
  }

  void init() {
    cudaFree(x_dev);
    cudaFree(v_dev);
    cudaFree(C_dev);
    cudaFree(J_dev);
    cudaFree(grid_v_dev);
    cudaFree(grid_m_dev);

    cudaMalloc(&x_dev, n_particles * sizeof(Vector));
    cudaMalloc(&v_dev, n_particles * sizeof(Vector));
    cudaMalloc(&C_dev, n_particles * sizeof(Matrix));
    cudaMalloc(&J_dev, n_particles * sizeof(Real));
    cudaMalloc(&grid_v_dev, utils::power(n_grid, dim) * sizeof(Vector));
    cudaMalloc(&grid_m_dev, utils::power(n_grid, dim) * sizeof(Real));
    utils::cuda_check_error();

    // initialize x on the host and copy to the device
    auto x_host = std::make_unique<Vector[]>(n_particles);
    for (auto i = 0; i < n_particles; i++) {
      for (auto j = 0; j < dim; j++) {
        x_host[i][j] = Real(utils::rand_real());
      }
      x_host[i] = (x_host[i] * 0.4).array() + 0.15;
    }
    cudaMemcpy(x_dev, x_host.get(), n_particles * sizeof(Vector),
               cudaMemcpyHostToDevice);

    cudaDeviceProp prop{};
    cudaGetDeviceProperties(&prop, 0);
    int block_dim{64};
    threads_per_block = std::min(block_dim, prop.maxThreadsPerBlock);
    auto block_num = utils::get_block_num(n_particles, threads_per_block);
    init_kernel<<<block_num, threads_per_block>>>(J_dev);
    utils::cuda_check_error();
  }

  void reset() {
    auto particle_block_num =
        utils::get_block_num(n_particles, threads_per_block);
    auto grid_block_num =
        utils::get_block_num(utils::power(n_grid, dim), threads_per_block);
    reset_kernel<<<grid_block_num, threads_per_block>>>(grid_v_dev, grid_m_dev);
  }

  void advance() {
    auto T = steps;
    auto particle_block_num =
        utils::get_block_num(n_particles, threads_per_block);
    auto grid_block_num =
        utils::get_block_num(utils::power(n_grid, dim), threads_per_block);
    while (T--) {
      particle_to_grid_kernel<<<particle_block_num, threads_per_block>>>(
          x_dev, v_dev, C_dev, J_dev, grid_v_dev, grid_m_dev, dx, p_vol, p_mass,
          n_grid);
    }
  }

  std::unique_ptr<Vector[]> to_numpy() {
    auto x_host = std::make_unique<Vector[]>(n_particles);
    cudaMemcpy(x_host.get(), x_dev, n_particles * sizeof(Vector),
               cudaMemcpyDeviceToHost);

    return x_host;
  }

  int get_n_particles() const { return n_particles; }

public:
  int dim = 2;
  int n_grid = 128;
  int steps = 32;
  int n_particles = utils::power(n_grid, dim) / utils::power(2, dim - 1);
  int neighbour = 9; // 2D
  Real dx = 1.0 / n_grid;
  Real p_rho = 1.0;
  Real p_vol = utils::power(dx * 0.5, 2);
  Real p_mass = p_vol * p_rho;
  Real gravity = 9.8;
  int bound = 3;
  Real E = 400;
  int threads_per_block;
};

int main(const int argc, const char **argv) {
  int n_grid = 128;
  if (argc > 1) {
    n_grid = atoi(argv[1]);
  }

  MPM *mpm = new MPM(n_grid);
  // skip first run
  mpm->init();
  mpm->reset();
  mpm->advance();
  auto x = mpm->to_numpy();

  int num_frames{1024};
  auto start_time = std::chrono::high_resolution_clock::now();
  for (auto runs = 0; runs < num_frames; runs++) {
    mpm->advance();
    // comment out to exclude D2H transfer
    // auto x = mpm->to_numpy();
  }
  cudaDeviceSynchronize();
  auto end_time = std::chrono::high_resolution_clock::now();
  std::chrono::duration<double> diff = end_time - start_time;

  float time_ms = diff.count() * 1000 / num_frames;
  printf("{\"n_particles\":%d, \"time_ms\": %f}\n", mpm->get_n_particles(),
         /*time_ms*/ time_ms);

  return 0;
}
