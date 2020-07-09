/*
 * Copyright (c) 2019-2020, NVIDIA CORPORATION.
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

#pragma once

#include <mutex>
#include <unordered_map>
#include <utility>
#include <vector>

#include <cublas_v2.h>
#include <cusolverDn.h>
#include <cusolverSp.h>
#include <cusparse.h>

#include <common/cuml_comms_int.hpp>

#include <cuml/cuml.hpp>

#include <cuml/common/cuml_allocator.hpp>

#include <raft/handle.hpp>
#include "handle_impl.hpp"

namespace ML {

using MLCommon::deviceAllocator;
using MLCommon::hostAllocator;

/**
 * @todo: Add doxygen documentation
 */
class raftHandle_impl : public handle_impl {
 public:
  raftHandle_impl(int n_streams = cumlHandle::getDefaultNumInternalStreams());
  ~raftHandle_impl();

  virtual int getDevice() const;
  virtual void setStream(cudaStream_t stream);
  virtual cudaStream_t getStream() const;
  virtual void setDeviceAllocator(std::shared_ptr<deviceAllocator> allocator);
  virtual std::shared_ptr<deviceAllocator> getDeviceAllocator() const;
  virtual void setHostAllocator(std::shared_ptr<hostAllocator> allocator);
  virtual std::shared_ptr<hostAllocator> getHostAllocator() const;

  virtual cublasHandle_t getCublasHandle() const;
  virtual cusolverDnHandle_t getcusolverDnHandle() const;
  virtual cusolverSpHandle_t getcusolverSpHandle() const;
  virtual cusparseHandle_t getcusparseHandle() const;

  virtual cudaStream_t getInternalStream(int sid) const;
  virtual int getNumInternalStreams() const;

  virtual std::vector<cudaStream_t> getInternalStreams() const;

  virtual void waitOnUserStream() const;
  virtual void waitOnInternalStreams() const;

  virtual void setCommunicator(
    std::shared_ptr<MLCommon::cumlCommunicator> communicator);
  virtual const MLCommon::cumlCommunicator& getCommunicator() const;
  virtual bool commsInitialized() const;

  virtual const cudaDeviceProp& getDeviceProperties() const;

  raft::handle_t& getRaftHandle() const;

 private:
  std::shared_ptr<deviceAllocator> _deviceAllocator;
  std::shared_ptr<hostAllocator> _hostAllocator;
  std::shared_ptr<MLCommon::cumlCommunicator> _communicator;

  raft::handle_t* _raftHandle;
};

}  // end namespace ML