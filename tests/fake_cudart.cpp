// Copyright 2026 Thornbots
// SPDX-License-Identifier: Apache-2.0
#include <cstdint>
#include <cstdlib>
namespace {
int result(int stage) {
  const char *value = std::getenv("FAKE_CUDA_STAGE");
  return value && std::atoi(value) == stage ? 801 : 0;
}
}
extern "C" {
int cudaDriverGetVersion(int *value) { *value = 13000; return 0; }
int cudaRuntimeGetVersion(int *value) { *value = 13000; return 0; }
int cudaGetDeviceCount(int *value) { *value = 1; return result(1); }
int cudaFree(void *) { return result(2); }
int cudaDeviceGetDefaultMemPool(void **pool, int device) {
  if (device != 0) { return 999; }
  *pool = reinterpret_cast<void *>(1); return result(3);
}
int cudaMemPoolSetAttribute(void *pool, int attribute, void *value) {
  if (pool != reinterpret_cast<void *>(1) || attribute != 4 ||
    *static_cast<std::uint64_t *>(value) != (std::uint64_t{1} << 30)) { return 999; }
  return result(4);
}
int cudaGetLastError() { return 0; }
const char *cudaGetErrorString(int) { return "operation not supported"; }
}
