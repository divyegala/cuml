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
#include <common/device_buffer.hpp>
#include <common/device_utils.cuh>
#include <raft/linalg/eltwise.cuh>
#include <raft/stats/sum.cuh>
#include "fft_kernels.cuh"
#include "utils.cuh"

namespace ML {
namespace TSNE {

struct isnan_test {

  template<typename value_t>
  __host__ __device__ bool operator()(const value_t a) const {
    return isnan(a);
  }
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
  CUDA_CHECK(cudaStreamSynchronize(stream));
  CUDA_CHECK(cudaPeekAtLastError());


  DB(value_t, y_tilde_spacings_device, n_interpolation_points);
  CUDA_CHECK(cudaMemcpyAsync(y_tilde_spacings_device.data(), y_tilde_spacings,
                             n_interpolation_points * sizeof(value_t),
                             cudaMemcpyHostToDevice, stream));
  DB(value_t, denominator_device, n_interpolation_points);
  CUDA_CHECK(cudaMemcpyAsync(denominator_device.data(), denominator,
                             n_interpolation_points * sizeof(value_t),
                             cudaMemcpyHostToDevice, stream));
#undef DB

  CUDA_CHECK(cudaStreamSynchronize(stream));
  CUDA_CHECK(cudaPeekAtLastError());

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

  CUDA_CHECK(cudaStreamSynchronize(stream));
  CUDA_CHECK(cudaPeekAtLastError());

  value_t momentum = pre_momentum;
  value_t learning_rate = pre_learning_rate;
  value_t exaggeration = early_exaggeration;

  if (initialize_embeddings) {
    printf("Initializing embeddings!\n");
    random_vector(Y, -0.0001f, 0.0001f, n * 2, stream, random_state);
  }

  for (int iter = 0; iter < max_iter; iter++) {

    if(iter % 100 == 0)
      printf("Iteration %d\n", iter);

    CUDA_CHECK(cudaStreamSynchronize(stream));
    CUDA_CHECK(cudaPeekAtLastError());

    thrust::device_ptr<value_t> d_ptr = thrust::device_pointer_cast(Y);
    bool h_result = thrust::transform_reduce(d_ptr, d_ptr+(n*2), isnan_test(), 0, thrust::plus<bool>());

    if(h_result)
      printf("Y nan after random vector? = %d\n",h_result);


    CUDA_CHECK(cudaStreamSynchronize(stream));
      CUDA_CHECK(cudaPeekAtLastError());
      bool i_result = thrust::transform_reduce(d_ptr, d_ptr+(n*2), isnan_test(), 0, thrust::plus<bool>());

      if(i_result)
        printf("Y nan before compute_charges? = %d\n",i_result);

      // Compute charges Q_ij
      int num_threads = 1024;
      int num_blocks = raft::ceildiv(n, (value_idx)num_threads);
      FFT::compute_chargesQij<<<num_blocks, num_threads, 0, stream>>>(
        chargesQij_device.data(), Y, Y + n, n, n_terms);
      CUDA_CHECK(cudaStreamSynchronize(stream));
      CUDA_CHECK(cudaPeekAtLastError());
      bool j_result = thrust::transform_reduce(d_ptr, d_ptr+n, isnan_test(), 0, thrust::plus<bool>());

      if(j_result)
        printf("Y nan after compute_charges? = %d\n",j_result);


    if (iter == exaggeration_iter) {
      momentum = post_momentum;
      learning_rate = post_learning_rate;
      exaggeration = late_exaggeration;
    }

    CUDA_CHECK(cudaMemsetAsync(w_coefficients_device.data(), 0.0, w_coefficients_device.size() * sizeof(value_t), stream));
    CUDA_CHECK(cudaMemsetAsync(potentialsQij_device.data(), 0.0, potentialsQij_device.size() * sizeof(value_t), stream));
    CUDA_CHECK(cudaMemsetAsync(attractive_forces_device.data(), 0.0, attractive_forces_device.size() * sizeof(value_t), stream));

//    MLCommon::LinAlg::zero(w_coefficients_device.data(),
//                           w_coefficients_device.size(), stream);
//    MLCommon::LinAlg::zero(potentialsQij_device.data(),
//                           potentialsQij_device.size(), stream);
    // TODO is this necessary inside the loop? IntegrationKernel zeros it.
//    MLCommon::LinAlg::zero(attractive_forces_device.data(),
//                           attractive_forces_device.size(), stream);


    auto y_thrust = thrust::device_pointer_cast(Y);
    auto minimax_iter = thrust::minmax_element(thrust::cuda::par.on(stream),
                                               y_thrust, y_thrust + n * 2);

    CUDA_CHECK(cudaStreamSynchronize(stream));

    value_t min_coord = *minimax_iter.first;
    value_t max_coord = *minimax_iter.second;
    value_t box_width =
      (max_coord - min_coord) / static_cast<value_t>(n_boxes_per_dim);


    if(isnan(box_width))
      printf("Box width: %f\n", box_width);

    //// Precompute FFT

      // Left and right bounds of each box, first the lower bounds in the x
      // direction, then in the y direction
      num_threads = 32;
      num_blocks =
        raft::ceildiv(n_total_boxes, (value_idx)num_threads);
      FFT::compute_bounds<<<num_blocks, num_threads, 0, stream>>>(
        box_lower_bounds_device.data(), box_width, min_coord, min_coord,
        n_boxes_per_dim, n_total_boxes);
      CUDA_CHECK(cudaPeekAtLastError());


      // Evaluate the kernel at the interpolation nodes and form the embedded
      // generating kernel vector for a circulant matrix.
      // Coordinates of all the equispaced interpolation points
      value_t h = box_width / n_interpolation_points;
      num_threads = 32;
      num_blocks =
        raft::ceildiv(n_interpolation_points_1d * n_interpolation_points_1d,
                      (value_idx)num_threads);
      FFT::compute_kernel_tilde<<<num_blocks, num_threads, 0, stream>>>(
        kernel_tilde_device.data(), min_coord, min_coord, h,
        n_interpolation_points_1d, n_fft_coeffs);
      CUDA_CHECK(cudaPeekAtLastError());

      // Precompute the FFT of the kernel generating matrix
      CUFFT_TRY(cufftExecR2C(plan_kernel_tilde, kernel_tilde_device.data(),
                             fft_kernel_tilde_device.data()));

    //// Run N-body FFT
      num_threads = 128;

      num_blocks = raft::ceildiv(n, (value_idx)num_threads);
      FFT::compute_point_box_idx<<<num_blocks, num_threads, 0, stream>>>(
        point_box_idx_device.data(), x_in_box_device.data(),
        y_in_box_device.data(), Y, Y + n, box_lower_bounds_device.data(),
        min_coord, box_width, n_boxes_per_dim, n_total_boxes, n);
      CUDA_CHECK(cudaPeekAtLastError());

      // Step 1: Interpolate kernel using Lagrange polynomials and compute the w
      // coefficients.

      // Compute the interpolated values at each real point with each Lagrange
      // polynomial in the `x` direction
      num_blocks =
        raft::ceildiv(n * n_interpolation_points, (value_idx)num_threads);
      FFT::interpolate_device<<<num_blocks, num_threads, 0, stream>>>(
        x_interpolated_values_device.data(), x_in_box_device.data(),
        y_tilde_spacings_device.data(), denominator_device.data(),
        n_interpolation_points, n);
      CUDA_CHECK(cudaPeekAtLastError());

      // ...and in the `y` direction
      FFT::interpolate_device<<<num_blocks, num_threads, 0, stream>>>(
        y_interpolated_values_device.data(), y_in_box_device.data(),
        y_tilde_spacings_device.data(), denominator_device.data(),
        n_interpolation_points, n);
      CUDA_CHECK(cudaPeekAtLastError());

      num_blocks = raft::ceildiv(
        n_terms * n_interpolation_points * n_interpolation_points * n,
        (value_idx)num_threads);
      FFT::compute_interpolated_indices<<<num_blocks, num_threads, 0, stream>>>(
        w_coefficients_device.data(), point_box_idx_device.data(),
        chargesQij_device.data(), x_interpolated_values_device.data(),
        y_interpolated_values_device.data(), n, n_interpolation_points,
        n_boxes_per_dim, n_terms);
      CUDA_CHECK(cudaPeekAtLastError());

      // Step 2: Compute the values v_{m, n} at the equispaced nodes, multiply
      // the kernel matrix with the coefficients w
      num_blocks =
        raft::ceildiv(n_terms * n_fft_coeffs_half * n_fft_coeffs_half,
                      (value_idx)num_threads);
      FFT::copy_to_fft_input<<<num_blocks, num_threads, 0, stream>>>(
        fft_input.data(), w_coefficients_device.data(), n_fft_coeffs,
        n_fft_coeffs_half, n_terms);
      CUDA_CHECK(cudaPeekAtLastError());

      // Compute fft values at interpolated nodes
      CUFFT_TRY(
        cufftExecR2C(plan_dft, fft_input.data(), fft_w_coefficients.data()));
      CUDA_CHECK(cudaPeekAtLastError());

      // Take the broadcasted Hadamard product of a complex matrix and a complex
      // vector.
        const value_idx nn = n_fft_coeffs * (n_fft_coeffs / 2 + 1);
        num_threads = 32;
        num_blocks =
          raft::ceildiv(nn * n_terms, (value_idx)num_threads);
        FFT::broadcast_column_vector<<<num_blocks, num_threads, 0, stream>>>(
          fft_w_coefficients.data(), fft_kernel_tilde_device.data(), nn,
          n_terms);
        CUDA_CHECK(cudaPeekAtLastError());

      // Invert the computed values at the interpolated nodes.
      CUFFT_TRY(
        cufftExecC2R(plan_idft, fft_w_coefficients.data(), fft_output.data()));
      FFT::copy_from_fft_output<<<num_blocks, num_threads, 0, stream>>>(
        y_tilde_values.data(), fft_output.data(), n_fft_coeffs,
        n_fft_coeffs_half, n_terms);
      CUDA_CHECK(cudaPeekAtLastError());

      // Step 3: Compute the potentials \tilde{\phi}
      num_blocks = raft::ceildiv(
        n_terms * n_interpolation_points * n_interpolation_points * n,
        (value_idx)num_threads);
      FFT::compute_potential_indices<value_idx, value_t, n_terms,
                                     n_interpolation_points>
        <<<num_blocks, num_threads, 0, stream>>>(
          potentialsQij_device.data(), point_box_idx_device.data(),
          y_tilde_values.data(), x_interpolated_values_device.data(),
          y_interpolated_values_device.data(), n, n_boxes_per_dim);
      CUDA_CHECK(cudaPeekAtLastError());


    value_t normalization;
      // Compute repulsive forces
      // Make the negative term, or F_rep in the equation 3 of the paper.
      num_threads = 1024;
      num_blocks = raft::ceildiv(n, (value_idx)num_threads);
      FFT::
        compute_repulsive_forces_kernel<<<num_blocks, num_threads, 0, stream>>>(
          repulsive_forces_device.data(), normalization_vec_device.data(), Y,
          Y + n, potentialsQij_device.data(), n, n_terms);
      CUDA_CHECK(cudaPeekAtLastError());

      raft::stats::sum(sum_d.data(), normalization_vec_device.data(),
                       (value_idx)1, n, true, stream);
      value_t sumQ;
      CUDA_CHECK(cudaMemcpyAsync(&sumQ, sum_d.data(), sizeof(value_t),
                                 cudaMemcpyDeviceToHost, stream));
      normalization = sumQ - n;

      // Compute attractive forces
      num_threads = 1024;
      num_blocks = raft::ceildiv(NNZ, (value_idx)num_threads);
      FFT::compute_Pij_x_Qij_kernel<<<num_blocks, num_threads, 0, stream>>>(
        attractive_forces_device.data(), VAL, ROW, COL, Y, n, NNZ);

      CUDA_CHECK(cudaStreamSynchronize(stream));
      CUDA_CHECK(cudaPeekAtLastError());
      bool k_result = thrust::transform_reduce(d_ptr, d_ptr+n, isnan_test(), 0, thrust::plus<bool>());

      if(k_result)
        printf("Y nan after compute_repulsive_forces_kernel? = %d\n",k_result);

      // Apply Forces
      num_threads = 1024;
      num_blocks = mp_count * integration_kernel_factor;
      FFT::IntegrationKernel<<<num_blocks, num_threads, 0, stream>>>(
        Y, attractive_forces_device.data(), repulsive_forces_device.data(),
        gains_device.data(), old_forces_device.data(), learning_rate,
        normalization, momentum, exaggeration, n);
      CUDA_CHECK(cudaPeekAtLastError());


    // TODO if (iter > exaggeration_iter && grad_norm < min_grad_norm) break

  }

  CUFFT_TRY(cufftDestroy(plan_kernel_tilde));
  CUFFT_TRY(cufftDestroy(plan_dft));
  CUFFT_TRY(cufftDestroy(plan_idft));
}

}  // namespace TSNE
}  // namespace ML
