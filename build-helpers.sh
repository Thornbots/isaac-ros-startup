#!/bin/bash
# Build on the robot host; CUDA headers and libraries are not needed.
set -euo pipefail
src=$(dirname "$(readlink -f "$0")")
destination=${1:-"$src/build"}
mkdir -p "$destination"
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Wpedantic "$src/src/log_stamp.cpp" -o "$destination/log-stamp"
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Wpedantic "$src/src/cuda_probe.cpp" -ldl -o "$destination/cuda-probe"
