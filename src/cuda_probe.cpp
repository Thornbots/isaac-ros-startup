// Copyright 2026 Thornbots
// SPDX-License-Identifier: Apache-2.0
#include <dlfcn.h>
#include <cstdint>
#include <cstdio>
#include <string>

int main() {
  void *runtime = nullptr;
  const char *loaded = nullptr;
  for (const char *name : {"libcudart.so", "libcudart.so.13", "libcudart.so.12",
      "/usr/local/cuda/lib64/libcudart.so"}) {
    runtime = dlopen(name, RTLD_LAZY);
    if (runtime) { loaded = name; break; }
  }
  if (!runtime) { std::puts("NO_CUDART"); return 2; }
  auto version = [&](const char *name, int *value) {
    const auto fn = reinterpret_cast<int (*)(int *)>(dlsym(runtime, name));
    return fn ? fn(value) : -1;
  };
  auto fail = [&](const std::string &stage, int code, int exit_code) {
    const auto clear = reinterpret_cast<int (*)()>(dlsym(runtime, "cudaGetLastError"));
    if (clear) { clear(); }
    const auto error = reinterpret_cast<const char *(*)(int)>(dlsym(runtime, "cudaGetErrorString"));
    const char *description = error ? error(code) : nullptr;
    std::printf("%s err=%d(%s) lib=%s\n", stage.c_str(), code, description ? description : "?", loaded);
    dlclose(runtime);
    return exit_code;
  };
  int driver = -1, run = -1, devices = -1;
  version("cudaDriverGetVersion", &driver); version("cudaRuntimeGetVersion", &run);
  int code = version("cudaGetDeviceCount", &devices);
  const std::string versions = " drv=" + std::to_string(driver) + " run=" + std::to_string(run);
  if (code) { return fail("DEVICE_COUNT_FAIL" + versions, code, 6); }
  const auto free_fn = reinterpret_cast<int (*)(void *)>(dlsym(runtime, "cudaFree"));
  code = free_fn ? free_fn(nullptr) : -1;
  if (code) { return fail("CTX_INIT_FAIL" + versions + " ndev=" + std::to_string(devices), code, 3); }
  void *pool = nullptr;
  const auto get_pool = reinterpret_cast<int (*)(void **, int)>(dlsym(runtime, "cudaDeviceGetDefaultMemPool"));
  code = get_pool ? get_pool(&pool, 0) : -1;
  if (code) { return fail("GET_POOL_FAIL", code, 4); }
  const std::uint64_t threshold = std::uint64_t{1} << 30;
  const auto set_attr = reinterpret_cast<int (*)(void *, int, void *)>(dlsym(runtime, "cudaMemPoolSetAttribute"));
  code = set_attr ? set_attr(pool, 4, const_cast<std::uint64_t *>(&threshold)) : -1;
  if (code) { return fail("SET_ATTR_FAIL", code, 5); }
  std::printf("OK drv=%d run=%d ndev=%d lib=%s\n", driver, run, devices, loaded);
  dlclose(runtime);
}
