/*
 * Copyright (c) 2021, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * This code is based on https://github.com/CannyLab/tsne-cuda (licensed under
 * the BSD 3-clause license at cannylabs_tsne_license.txt), which is in turn a
 * CUDA implementation of Linderman et al.'s FIt-SNE (MIT license)
 * (https://github.com/KlugerLab/FIt-SNE).
 */

#pragma once

#include <cufft_utils.h>
#include <linalg/init.h>
#include <cmath>
#include <common/device_utils.cuh>
#include <raft/linalg/eltwise.cuh>
#include <raft/mr/device/buffer.hpp>
#include <raft/stats/sum.cuh>
#include <rmm/device_vector.hpp>
#include "fft_kernels.cuh"
#include "utils.cuh"

namespace ML {
namespace TSNE {

const static int NTHREADS_1024 = 1024;
const static int NTHREADS_128 = 128;
const static int NTHREADS_32 = 32;

struct isnan_test {
  template <typename value_t>
  __host__ __device__ bool operator()(const value_t a) const {
    return isnan(a);
  }
};

struct FunctionalSqrt {
  __host__ __device__ float operator()(const float &x) const {
    return pow(x, 0.5);
  }
};
struct FunctionalSquare {
  __host__ __device__ float operator()(const float &x) const { return x * x; }
};
template <typename T>
cufftResult CUFFTAPI cufft_MakePlanMany(cufftHandle plan, T rank, T *n,
                                        T *inembed, T istride, T idist,
                                        T *onembed, T ostride, T odist,
                                        cufftType type, T batch,
                                        size_t *workSize);

cufftResult CUFFTAPI cufft_MakePlanMany(cufftHandle plan, int rank, int64_t *n,
                                        int64_t *inembed, int64_t istride,
                                        int64_t idist, int64_t *onembed,
                                        int64_t ostride, int64_t odist,
                                        cufftType type, int64_t batch,
                                        size_t *workSize) {
  return cufftMakePlanMany64(
    plan, rank, reinterpret_cast<long long int *>(n),
    reinterpret_cast<long long int *>(inembed),
    static_cast<long long int>(istride), static_cast<long long int>(idist),
    reinterpret_cast<long long int *>(onembed),
    static_cast<long long int>(ostride), static_cast<long long int>(odist),
    type, static_cast<long long int>(batch), workSize);
}
cufftResult CUFFTAPI cufft_MakePlanMany(cufftHandle plan, int rank, int *n,
                                        int *inembed, int istride, int idist,
                                        int *onembed, int ostride, int odist,
                                        cufftType type, int batch,
                                        size_t *workSize) {
  return cufftMakePlanMany(plan, rank, n, inembed, istride, idist, onembed,
                           ostride, odist, type, batch, workSize);
}

template <typename value_t, typename value_idx>
std::pair<value_t, value_t> min_max(const value_t *Y, const value_idx n,
                                    cudaStream_t stream, int iter) {
  value_t min_h, max_h;

  rmm::device_uvector<value_t> min_d(1, stream);
  rmm::device_uvector<value_t> max_d(1, stream);

  min_d.set_element(0, std::numeric_limits<value_t>::max(), stream);
  max_d.set_element(0, std::numeric_limits<value_t>::lowest(), stream);
  // rmm::device_vector<value_t> min_d(1, std::numeric_limits<value_t>::max());
  // rmm::device_vector<value_t> max_d(1, std::numeric_limits<value_t>::lowest());

  raft::update_host(&min_h, min_d.data(), 1, stream);
  raft::update_host(&max_h, max_d.data(), 1, stream);

  auto nthreads = 1024;
  auto nblocks = raft::ceildiv(n, (value_idx)nthreads);

  min_max_kernel<<<nblocks, nthreads, 0, stream>>>(Y, n, min_d.data(),
                                                   max_d.data(), true, iter);

  // raft::print_device_vector("Max_d", max_d.data(), 1, std::cout);
  raft::update_host(&min_h, min_d.data(), 1, stream);
  raft::update_host(&max_h, max_d.data(), 1, stream);
  // std::cout << "In function, min: " << min_h << ", max: " << max_h << std::endl;

  CUDA_CHECK(cudaDeviceSynchronize());

  return std::make_pair(std::move(min_h), std::move(max_h));
}

/**
 * @brief Fast Dimensionality reduction via TSNE using the Barnes Hut O(NlogN) approximation.
 * @param[in] VAL: The values in the attractive forces COO matrix.
 * @param[in] COL: The column indices in the attractive forces COO matrix.
 * @param[in] ROW: The row indices in the attractive forces COO matrix.
 * @param[in] NNZ: The number of non zeros in the attractive forces COO matrix.
 * @param[in] handle: The GPU handle.
 * @param[out] Y: The final embedding (col-major).
 * @param[in] n: Number of rows in data X.
 * @param[in] early_exaggeration: How much pressure to apply to clusters to spread out during the exaggeration phase.
 * @param[in] late_exaggeration: How much pressure to apply to clusters to spread out after the exaggeration phase.
 * @param[in] exaggeration_iter: How many iterations you want the early pressure to run for.
 * @param[in] pre_learning_rate: The learning rate during the exaggeration phase.
 * @param[in] post_learning_rate: The learning rate after the exaggeration phase.
 * @param[in] max_iter: The maximum number of iterations TSNE should run for.
 * @param[in] min_grad_norm: The smallest gradient norm TSNE should terminate on.
 * @param[in] pre_momentum: The momentum used during the exaggeration phase.
 * @param[in] post_momentum: The momentum used after the exaggeration phase.
 * @param[in] random_state: Set this to -1 for random intializations or >= 0 to see the PRNG.
 * @param[in] initialize_embeddings: Whether to overwrite the current Y vector with random noise.
 */
template <typename value_idx, typename value_t>
void FFT_TSNE(value_t *VAL, const value_idx *COL, const value_idx *ROW,
              const value_idx NNZ, const raft::handle_t &handle, value_t *Y,
              const value_idx n, const float early_exaggeration,
              const float late_exaggeration, const int exaggeration_iter,
              const float pre_learning_rate, const float post_learning_rate,
              const int max_iter, const float min_grad_norm,
              const float pre_momentum, const float post_momentum,
              const long long random_state, const bool initialize_embeddings) {
  auto d_alloc = handle.get_device_allocator();
  auto stream = handle.get_stream();

  // Get device properites
  //---------------------------------------------------
  const int mp_count = raft::getMultiProcessorCount();
  const int dev_major_version = MLCommon::getDeviceCapability().first;
  // These came from the CannyLab implementation, but I don't know how they were
  // determined. TODO check/optimize.
  const int integration_kernel_factor =
    dev_major_version >= 6
      ? 2
      : dev_major_version == 5 ? 1 : dev_major_version == 3 ? 2 : 3;

  constexpr value_idx n_interpolation_points = 3;
  constexpr value_idx min_num_intervals = 50;
  // The number of "charges" or s+2 sums i.e. number of kernel sums
  constexpr value_idx n_terms = 4;
  value_idx n_boxes_per_dim = min_num_intervals;

  // FFTW is faster on numbers that can be written as 2^a 3^b 5^c 7^d 11^e 13^f
  // where e+f is either 0 or 1, and the other exponents are arbitrary
  int allowed_n_boxes_per_dim[20] = {25,  36,  50,  55,  60,  65,  70,
                                     75,  80,  85,  90,  96,  100, 110,
                                     120, 130, 140, 150, 175, 200};
  if (n_boxes_per_dim < allowed_n_boxes_per_dim[19]) {
    // Round up to nearest grid point
    value_idx chosen_i = 0;
    while (allowed_n_boxes_per_dim[chosen_i] < n_boxes_per_dim) chosen_i++;
    n_boxes_per_dim = allowed_n_boxes_per_dim[chosen_i];
  }

  value_idx n_total_boxes = n_boxes_per_dim * n_boxes_per_dim;
  value_idx total_interpolation_points =
    n_total_boxes * n_interpolation_points * n_interpolation_points;
  value_idx n_fft_coeffs_half = n_interpolation_points * n_boxes_per_dim;
  value_idx n_fft_coeffs = 2 * n_interpolation_points * n_boxes_per_dim;
  value_idx n_interpolation_points_1d =
    n_interpolation_points * n_boxes_per_dim;

#define DB(type, name, size) \
  raft::mr::device::buffer<type> name(d_alloc, stream, size)

  DB(value_t, repulsive_forces_device, n * 2);
  MLCommon::LinAlg::zero(repulsive_forces_device.data(),
                         repulsive_forces_device.size(), stream);
  DB(value_t, attractive_forces_device, n * 2);
  DB(value_t, gains_device, n * 2);
  auto gains_device_thrust = thrust::device_pointer_cast(gains_device.data());
  thrust::fill(thrust::cuda::par.on(stream), gains_device_thrust,
               gains_device_thrust + (n * 2), 1.0f);
  DB(value_t, old_forces_device, n * 2);
  MLCommon::LinAlg::zero(old_forces_device.data(), old_forces_device.size(),
                         stream);
  DB(value_t, normalization_vec_device, n);
  DB(value_idx, point_box_idx_device, n);
  DB(value_t, x_in_box_device, n);
  DB(value_t, y_in_box_device, n);
  DB(value_t, y_tilde_values, total_interpolation_points * n_terms);
  DB(value_t, x_interpolated_values_device, n * n_interpolation_points);
  DB(value_t, y_interpolated_values_device, n * n_interpolation_points);
  DB(value_t, potentialsQij_device, n * n_terms);
  DB(value_t, w_coefficients_device, total_interpolation_points * n_terms);
  DB(value_t, all_interpolated_values_device,
     n_terms * n_interpolation_points * n_interpolation_points * n);
  DB(value_t, output_values,
     n_terms * n_interpolation_points * n_interpolation_points * n);
  DB(value_t, all_interpolated_indices,
     n_terms * n_interpolation_points * n_interpolation_points * n);
  DB(value_t, output_indices,
     n_terms * n_interpolation_points * n_interpolation_points * n);
  DB(value_t, chargesQij_device, n * n_terms);
  DB(value_t, box_lower_bounds_device, 2 * n_total_boxes);
  DB(value_t, kernel_tilde_device, n_fft_coeffs * n_fft_coeffs);
  DB(cufftComplex, fft_kernel_tilde_device,
     2 * n_interpolation_points_1d * 2 * n_interpolation_points_1d);
  DB(value_t, fft_input, n_terms * n_fft_coeffs * n_fft_coeffs);
  DB(cufftComplex, fft_w_coefficients,
     n_terms * n_fft_coeffs * (n_fft_coeffs / 2 + 1));
  DB(value_t, fft_output, n_terms * n_fft_coeffs * n_fft_coeffs);
  DB(value_t, sum_d, 1);

  value_t h = 1.0f / n_interpolation_points;
  value_t y_tilde_spacings[n_interpolation_points];
  y_tilde_spacings[0] = h / 2;
  for (value_idx i = 1; i < n_interpolation_points; i++) {
    y_tilde_spacings[i] = y_tilde_spacings[i - 1] + h;
  }
  value_t denominator[n_interpolation_points];
  for (value_idx i = 0; i < n_interpolation_points; i++) {
    denominator[i] = 1;
    for (value_idx j = 0; j < n_interpolation_points; j++) {
      if (i != j) {
        denominator[i] *= y_tilde_spacings[i] - y_tilde_spacings[j];
      }
    }
  }

  DB(value_t, y_tilde_spacings_device, n_interpolation_points);
  CUDA_CHECK(cudaMemcpyAsync(y_tilde_spacings_device.data(), y_tilde_spacings,
                             n_interpolation_points * sizeof(value_t),
                             cudaMemcpyHostToDevice, stream));
  DB(value_t, denominator_device, n_interpolation_points);
  CUDA_CHECK(cudaMemcpyAsync(denominator_device.data(), denominator,
                             n_interpolation_points * sizeof(value_t),
                             cudaMemcpyHostToDevice, stream));
#undef DB

  cufftHandle plan_kernel_tilde;
  cufftHandle plan_dft;
  cufftHandle plan_idft;

  CUFFT_TRY(cufftCreate(&plan_kernel_tilde));
  CUFFT_TRY(cufftSetStream(plan_kernel_tilde, stream));
  CUFFT_TRY(cufftCreate(&plan_dft));
  CUFFT_TRY(cufftSetStream(plan_dft, stream));
  CUFFT_TRY(cufftCreate(&plan_idft));
  CUFFT_TRY(cufftSetStream(plan_idft, stream));

  size_t work_size, work_size_dft, work_size_idft;
  value_idx fft_dimensions[2] = {n_fft_coeffs, n_fft_coeffs};
  CUFFT_TRY(cufftMakePlan2d(plan_kernel_tilde, fft_dimensions[0],
                            fft_dimensions[1], CUFFT_R2C, &work_size));
  CUFFT_TRY(cufft_MakePlanMany(
    plan_dft, 2, fft_dimensions, NULL, 1, n_fft_coeffs * n_fft_coeffs, NULL, 1,
    n_fft_coeffs * (n_fft_coeffs / 2 + 1), CUFFT_R2C, n_terms, &work_size_dft));
  CUFFT_TRY(cufft_MakePlanMany(plan_idft, 2, fft_dimensions, NULL, 1,
                               n_fft_coeffs * (n_fft_coeffs / 2 + 1), NULL, 1,
                               n_fft_coeffs * n_fft_coeffs, CUFFT_C2R, n_terms,
                               &work_size_idft));

  value_t momentum = pre_momentum;
  value_t learning_rate = pre_learning_rate;
  value_t exaggeration = early_exaggeration;

  if (initialize_embeddings) {
    random_vector(Y, 0.0000f, 0.0001f, n * 2, stream, random_state);
    // auto op = [] __device__ (const value_idx &i) {
    //   if (i % 2 == 0) {
    //     return -0.0001f;
    //   }
    //   else {
    //     return 0.0001f;
    //   }
    // };
    // thrust::transform(thrust::cuda::par.on(stream), thrust::make_counting_iterator(static_cast<value_idx>(0)), thrust::make_counting_iterator(static_cast<value_idx>(n * 2)), Y, op);
  }

  for (int iter = 0; iter < max_iter; iter++) {
    if (iter < 3 || iter > 996) {
      std::cout << "Iter: " << iter << std::endl;
    }
    thrust::device_ptr<value_t> d_ptr = thrust::device_pointer_cast(Y);
    bool h_result = thrust::transform_reduce(
      thrust::cuda::par.on(stream), d_ptr, d_ptr + (n * 2), isnan_test(), 0,
      thrust::plus<bool>());

    ASSERT(!h_result, "Output embedding (Y) contains nan values");

    // Compute charges Q_ij
    {
      int num_blocks = raft::ceildiv(n, (value_idx)NTHREADS_1024);
      FFT::compute_chargesQij<<<num_blocks, NTHREADS_1024, 0, stream>>>(
        chargesQij_device.data(), Y, Y + n, n, n_terms);
      // if (iter < 3 || iter > 996) {raft::print_device_vector("chargesQij", chargesQij_device.data(), 15,
      // std::cout);std::cout << std::endl;}

      CUDA_CHECK(cudaPeekAtLastError());
      CUDA_CHECK(cudaDeviceSynchronize());
    }

    if (iter == exaggeration_iter) {
      momentum = post_momentum;
      learning_rate = post_learning_rate;
      exaggeration = late_exaggeration;
    }

    MLCommon::LinAlg::zero(w_coefficients_device.data(),
                           w_coefficients_device.size(), stream);
    MLCommon::LinAlg::zero(potentialsQij_device.data(),
                           potentialsQij_device.size(), stream);
    // TODO is this necessary inside the loop? IntegrationKernel zeros it.
    MLCommon::LinAlg::zero(attractive_forces_device.data(),
                           attractive_forces_device.size(), stream);

    CUDA_CHECK(cudaDeviceSynchronize());
    auto minmax_pair = min_max(Y, n * 2, stream, iter);
    auto min_coord = minmax_pair.first;
    auto max_coord = minmax_pair.second;
    CUDA_CHECK(cudaPeekAtLastError());
    CUDA_CHECK(cudaDeviceSynchronize());

    value_t box_width =
      (max_coord - min_coord) / static_cast<value_t>(n_boxes_per_dim);
    // if (iter < 3 || iter > 996) {
    //   // raft::print_device_vector("Y", Y, n*2, std::cout);
    //   std::cout << std::endl << "min: " << min_coord << ", max: " << max_coord << std::endl;
    // }

    //// Precompute FFT

    // Left and right bounds of each box, first the lower bounds in the x
    // direction, then in the y direction
    {
      auto num_blocks = raft::ceildiv(n_total_boxes, (value_idx)NTHREADS_32);
      FFT::compute_bounds<<<num_blocks, NTHREADS_32, 0, stream>>>(
        box_lower_bounds_device.data(), box_width, min_coord, min_coord,
        n_boxes_per_dim, n_total_boxes);
      CUDA_CHECK(cudaPeekAtLastError());
      CUDA_CHECK(cudaDeviceSynchronize());
    }

    //  if (iter < 3 || iter > 996) {raft::print_device_vector("box_lower_bounds", box_lower_bounds_device.data(), 15, std::cout);std::cout << std::endl;}

    {
      // Evaluate the kernel at the interpolation nodes and form the embedded
      // generating kernel vector for a circulant matrix.
      // Coordinates of all the equispaced interpolation points
      value_t h = box_width / n_interpolation_points;
      auto num_blocks =
        raft::ceildiv(n_interpolation_points_1d * n_interpolation_points_1d,
                      (value_idx)NTHREADS_32);
      FFT::compute_kernel_tilde<<<num_blocks, NTHREADS_32, 0, stream>>>(
        kernel_tilde_device.data(), min_coord, min_coord, h,
        n_interpolation_points_1d, n_fft_coeffs);
      CUDA_CHECK(cudaPeekAtLastError());
      CUDA_CHECK(cudaDeviceSynchronize());
    }
    // if (iter < 3 || iter > 996) {raft::print_device_vector("kernel_tilde", kernel_tilde_device.data(), 15, std::cout);std::cout << std::endl;}

    {
      // Precompute the FFT of the kernel generating matrix
      CUFFT_TRY(cufftExecR2C(plan_kernel_tilde, kernel_tilde_device.data(),
                             fft_kernel_tilde_device.data()));
    }
    // if (iter < 3 || iter > 996) {raft::print_device_vector("fft_kernel_tilde", fft_kernel_tilde_device.data(), 15, std::cout);std::cout << std::endl;}

    CUDA_CHECK(cudaDeviceSynchronize());
    {
      //// Run N-body FFT
      auto num_blocks = raft::ceildiv(n, (value_idx)NTHREADS_128);
      FFT::compute_point_box_idx<<<num_blocks, NTHREADS_128, 0, stream>>>(
        point_box_idx_device.data(), x_in_box_device.data(),
        y_in_box_device.data(), Y, Y + n, box_lower_bounds_device.data(),
        min_coord, box_width, n_boxes_per_dim, n_total_boxes, n);
      CUDA_CHECK(cudaPeekAtLastError());
      CUDA_CHECK(cudaDeviceSynchronize());
      // if (iter < 3 || iter > 996) {raft::print_device_vector("point_box_idx", point_box_idx_device.data(), 15, std::cout);std::cout << std::endl;}
      // if (iter < 3 || iter > 996) {raft::print_device_vector("x_in_box", x_in_box_device.data(), 15, std::cout);std::cout << std::endl;}
      // if (iter < 3 || iter > 996) {raft::print_device_vector("y_in_box", y_in_box_device.data(), 15, std::cout);std::cout << std::endl;}

      // raft::print_device_vector(
      //   "w_coefficients_device", w_coefficients_device.data(),
      //   min(15, (int)w_coefficients_device.size()), std::cout);

      // Step 1: Interpolate kernel using Lagrange polynomials and compute the w
      // coefficients.

      // Compute the interpolated values at each real point with each Lagrange
      // polynomial in the `x` direction
      num_blocks =
        raft::ceildiv(n * n_interpolation_points, (value_idx)NTHREADS_128);
      FFT::interpolate_device<<<num_blocks, NTHREADS_128, 0, stream>>>(
        x_interpolated_values_device.data(), x_in_box_device.data(),
        y_tilde_spacings_device.data(), denominator_device.data(),
        n_interpolation_points, n);
      CUDA_CHECK(cudaPeekAtLastError());
      CUDA_CHECK(cudaDeviceSynchronize());
      // if (iter < 3 || iter > 996) {raft::print_device_vector("x_interpolated_values", x_interpolated_values_device.data(), 15, std::cout);std::cout << std::endl;}

      // ...and in the `y` direction
      FFT::interpolate_device<<<num_blocks, NTHREADS_128, 0, stream>>>(
        y_interpolated_values_device.data(), y_in_box_device.data(),
        y_tilde_spacings_device.data(), denominator_device.data(),
        n_interpolation_points, n);
      CUDA_CHECK(cudaPeekAtLastError());
      CUDA_CHECK(cudaDeviceSynchronize());
      // if (iter < 3 || iter > 996) {raft::print_device_vector("y_interpolated_values", y_interpolated_values_device.data(), 15, std::cout);std::cout << std::endl;}

      num_blocks = raft::ceildiv(
        n_terms * n_interpolation_points * n_interpolation_points * n,
        (value_idx)NTHREADS_128);
      FFT::
        compute_interpolated_indices<<<num_blocks, NTHREADS_128, 0, stream>>>(
          w_coefficients_device.data(), point_box_idx_device.data(),
          chargesQij_device.data(), x_interpolated_values_device.data(),
          y_interpolated_values_device.data(), n, n_interpolation_points,
          n_boxes_per_dim, n_terms);
      CUDA_CHECK(cudaPeekAtLastError());
      CUDA_CHECK(cudaDeviceSynchronize());

      // if (iter < 3 || iter > 996) {raft::print_device_vector("w_coefficients", w_coefficients_device.data(), 15, std::cout);std::cout << std::endl;}

      // raft::print_device_vector(
      //   "w_coefficients_device", w_coefficients_device.data(),
      //   min(15, (int)w_coefficients_device.size()), std::cout);

      // Step 2: Compute the values v_{m, n} at the equispaced nodes, multiply
      // the kernel matrix with the coefficients w
      num_blocks =
        raft::ceildiv(n_terms * n_fft_coeffs_half * n_fft_coeffs_half,
                      (value_idx)NTHREADS_128);
      FFT::copy_to_fft_input<<<num_blocks, NTHREADS_128, 0, stream>>>(
        fft_input.data(), w_coefficients_device.data(), n_fft_coeffs,
        n_fft_coeffs_half, n_terms);
      CUDA_CHECK(cudaPeekAtLastError());
      CUDA_CHECK(cudaDeviceSynchronize());

      // if (iter < 3 || iter > 996) {raft::print_device_vector("fft_input", fft_input.data(), 15, std::cout);std::cout << std::endl;}

      // Compute fft values at interpolated nodes
      CUFFT_TRY(
        cufftExecR2C(plan_dft, fft_input.data(), fft_w_coefficients.data()));
      CUDA_CHECK(cudaPeekAtLastError());
      CUDA_CHECK(cudaDeviceSynchronize());
      // if (iter < 3 || iter > 996) {raft::print_device_vector("fft_w_coefficients", fft_w_coefficients.data(), 15, std::cout);std::cout << std::endl;}

      // Take the broadcasted Hadamard product of a complex matrix and a complex
      // vector.
      {
        const value_idx nn = n_fft_coeffs * (n_fft_coeffs / 2 + 1);
        auto num_blocks = raft::ceildiv(nn * n_terms, (value_idx)NTHREADS_32);
        FFT::broadcast_column_vector<<<num_blocks, NTHREADS_32, 0, stream>>>(
          fft_w_coefficients.data(), fft_kernel_tilde_device.data(), nn,
          n_terms);
        CUDA_CHECK(cudaPeekAtLastError());
        CUDA_CHECK(cudaDeviceSynchronize());
      }
      // if (iter < 3 || iter > 996) {raft::print_device_vector("fft_w_coefficients", fft_w_coefficients.data(), 15, std::cout);std::cout << std::endl;}

      // raft::print_device_vector("fft_input", fft_input.data(),
      //                           min(15, (int)fft_input.size()), std::cout);

      // Invert the computed values at the interpolated nodes.
      CUFFT_TRY(
        cufftExecC2R(plan_idft, fft_w_coefficients.data(), fft_output.data()));
      CUDA_CHECK(cudaPeekAtLastError());
      CUDA_CHECK(cudaDeviceSynchronize());
      if (iter < 3 || iter > 996) {
        raft::print_device_vector("fft_output", fft_output.data() + 45150, 15,
                                  std::cout);
        std::cout << std::endl;
      }

      FFT::copy_from_fft_output<<<num_blocks, NTHREADS_128, 0, stream>>>(
        y_tilde_values.data(), fft_output.data(), n_fft_coeffs,
        n_fft_coeffs_half, n_terms, iter);
      CUDA_CHECK(cudaPeekAtLastError());
      CUDA_CHECK(cudaDeviceSynchronize());
      if (iter < 3 || iter > 996) {
        // std::cout << "n_fft_coeffs: " << n_fft_coeffs << ", n_fft_coeffs_half: " << n_fft_coeffs_half << ", n_terms: " << n_terms << std::endl;
        raft::print_device_vector("y_tilde_values", y_tilde_values.data(), 15,
                                  std::cout);
        std::cout << std::endl;
      }

      // raft::print_device_vector("fft_output", fft_output.data(),
      //                           min(15, (int)fft_output.size()), std::cout);

      // Step 3: Compute the potentials \tilde{\phi}
      num_blocks = raft::ceildiv(
        n_terms * n_interpolation_points * n_interpolation_points * n,
        (value_idx)NTHREADS_128);
      FFT::compute_potential_indices<value_idx, value_t, n_terms,
                                     n_interpolation_points>
        <<<num_blocks, NTHREADS_128, 0, stream>>>(
          potentialsQij_device.data(), point_box_idx_device.data(),
          y_tilde_values.data(), x_interpolated_values_device.data(),
          y_interpolated_values_device.data(), n, n_boxes_per_dim);
      CUDA_CHECK(cudaPeekAtLastError());
      CUDA_CHECK(cudaDeviceSynchronize());
    }

    if (iter < 3 || iter > 996) {
      raft::print_device_vector("potentialsQij", potentialsQij_device.data(),
                                15, std::cout);
      std::cout << std::endl;
    }
    // if (iter > 997) {raft::print_device_vector("potentialsQij", potentialsQij_device.data(), 15,
    // std::cout);std::cout << std::endl;}

    value_t normalization;
    {
      // Compute repulsive forces
      // Make the negative term, or F_rep in the equation 3 of the paper.
      auto num_blocks = raft::ceildiv(n, (value_idx)NTHREADS_1024);
      FFT::compute_repulsive_forces_kernel<<<num_blocks, NTHREADS_1024, 0,
                                             stream>>>(
        repulsive_forces_device.data(), normalization_vec_device.data(), Y,
        Y + n, potentialsQij_device.data(), n, n_terms);
      CUDA_CHECK(cudaPeekAtLastError());

      CUDA_CHECK(cudaDeviceSynchronize());
      auto norm_vec_thrust =
        thrust::device_pointer_cast(normalization_vec_device.data());

      value_t sumQ =
        thrust::reduce(thrust::cuda::par.on(stream), norm_vec_thrust,
                       norm_vec_thrust + normalization_vec_device.size(), 0.0f,
                       thrust::plus<value_t>());
      normalization = sumQ - n;
    }

    CUDA_CHECK(cudaDeviceSynchronize());
    // Compute attractive forces
    {
      auto num_blocks = raft::ceildiv(NNZ, (value_idx)NTHREADS_1024);
      FFT::compute_Pij_x_Qij_kernel<<<num_blocks, NTHREADS_1024, 0, stream>>>(
        attractive_forces_device.data(), VAL, ROW, COL, Y, n, NNZ);
    }

    CUDA_CHECK(cudaDeviceSynchronize());  // Apply Forces
    {
      auto num_blocks = mp_count * integration_kernel_factor;

      FFT::IntegrationKernel<<<num_blocks, NTHREADS_1024, 0, stream>>>(
        Y, attractive_forces_device.data(), repulsive_forces_device.data(),
        gains_device.data(), old_forces_device.data(), learning_rate,
        normalization, momentum, exaggeration, n);
    }
    CUDA_CHECK(cudaPeekAtLastError());

    CUDA_CHECK(cudaDeviceSynchronize());

    h_result = thrust::transform_reduce(thrust::cuda::par.on(stream), d_ptr,
                                        d_ptr + (n * 2), isnan_test(), 0,
                                        thrust::plus<bool>());

    ASSERT(!h_result, "Output embedding (Y) contains nan values (end)");

    auto att_forces_thrust =
      thrust::device_pointer_cast(attractive_forces_device.data());
    auto old_forces_thrust =
      thrust::device_pointer_cast(old_forces_device.data());

    thrust::transform(thrust::cuda::par.on(stream), old_forces_thrust,
                      old_forces_thrust + n, att_forces_thrust,
                      FunctionalSquare());

    thrust::transform(thrust::cuda::par.on(stream), att_forces_thrust,
                      att_forces_thrust + n, att_forces_thrust + n,
                      att_forces_thrust, thrust::plus<value_t>());

    thrust::transform(thrust::cuda::par.on(stream), att_forces_thrust,
                      att_forces_thrust + attractive_forces_device.size(),
                      att_forces_thrust, FunctionalSqrt());

    value_t grad_norm =
      thrust::reduce(thrust::cuda::par.on(stream), att_forces_thrust,
                     att_forces_thrust + attractive_forces_device.size(), 0.0f,
                     thrust::plus<value_t>()) /
      attractive_forces_device.size();

    CUDA_CHECK(cudaDeviceSynchronize());

    if (grad_norm <= min_grad_norm) {
      std::cout << "Broke early with: " << grad_norm << ", at iter: " << iter
                << std::endl;
      raft::print_device_vector("potentialsQij", potentialsQij_device.data(),
                                15, std::cout);
      break;
    }

    if (iter == 999) printf("grad_norm: %f\n", grad_norm);
  }

  CUDA_CHECK(cudaDeviceSynchronize());
  CUFFT_TRY(cufftDestroy(plan_kernel_tilde));
  CUFFT_TRY(cufftDestroy(plan_dft));
  CUFFT_TRY(cufftDestroy(plan_idft));
}

}  // namespace TSNE
}  // namespace ML