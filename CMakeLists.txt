cmake_minimum_required(VERSION 3.16)
project(thornbots_startup LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_compile_options(-Wall -Wextra -Wpedantic)
add_executable(log-stamp src/log_stamp.cpp)
add_executable(match-wifi-off src/match_wifi_off.cpp)
add_executable(mmm-poweroff src/mmm_poweroff.cpp)
add_executable(cuda-probe src/cuda_probe.cpp)
target_link_libraries(cuda-probe PRIVATE ${CMAKE_DL_LIBS})
include(CTest)
if(BUILD_TESTING)
  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  add_test(NAME eduroam COMMAND ${Python3_EXECUTABLE}
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_eduroam.py ${CMAKE_CURRENT_SOURCE_DIR})
  set_tests_properties(eduroam PROPERTIES TIMEOUT 30)
  add_test(NAME mmm_wiring COMMAND ${Python3_EXECUTABLE}
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_mmm_wiring.py ${CMAKE_CURRENT_SOURCE_DIR})
  set_tests_properties(mmm_wiring PROPERTIES TIMEOUT 30)
  add_test(NAME camera_power_cycle COMMAND ${Python3_EXECUTABLE}
    ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_camera_power_cycle.py ${CMAKE_CURRENT_SOURCE_DIR})
  set_tests_properties(camera_power_cycle PROPERTIES TIMEOUT 30)
  add_executable(test_match_wifi_off tests/test_match_wifi_off.cpp src/match_wifi_off.cpp)
  target_compile_definitions(test_match_wifi_off PRIVATE THORNBOTS_WIFI_NO_MAIN)
  add_test(NAME match_wifi_off COMMAND test_match_wifi_off)
  set_tests_properties(match_wifi_off PROPERTIES TIMEOUT 10)
  add_executable(test_mmm_poweroff tests/test_mmm_poweroff.cpp src/mmm_poweroff.cpp)
  target_compile_definitions(test_mmm_poweroff PRIVATE THORNBOTS_MMM_NO_MAIN)
  add_test(NAME mmm_poweroff COMMAND test_mmm_poweroff)
  set_tests_properties(mmm_poweroff PROPERTIES TIMEOUT 10)
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
