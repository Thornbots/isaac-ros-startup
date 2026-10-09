cmake_minimum_required(VERSION 3.16)
project(thornbots_startup LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_compile_options(-Wall -Wextra -Wpedantic)
add_executable(log-stamp src/log_stamp.cpp)
add_executable(cuda-probe src/cuda_probe.cpp)
target_link_libraries(cuda-probe PRIVATE ${CMAKE_DL_LIBS})
include(CTest)
if(BUILD_TESTING)
  add_executable(test_log_stamp tests/test_log_stamp.cpp)
  add_test(NAME log_stamp COMMAND test_log_stamp $<TARGET_FILE:log-stamp>)
  set_tests_properties(log_stamp PROPERTIES TIMEOUT 10)
  add_library(fake_cudart SHARED tests/fake_cudart.cpp)
  set_target_properties(fake_cudart PROPERTIES OUTPUT_NAME cudart)
  foreach(stage IN ITEMS 0 1 2 3 4)
    add_test(NAME cuda_probe_${stage}
      COMMAND ${CMAKE_COMMAND}
        "-DPROBE=$<TARGET_FILE:cuda-probe>"
        "-DLIBRARY_DIR=$<TARGET_FILE_DIR:fake_cudart>"
        "-DSTAGE=${stage}"
        -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_cuda_probe.cmake)
  endforeach()
endif()
