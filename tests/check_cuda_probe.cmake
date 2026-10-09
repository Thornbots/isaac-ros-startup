execute_process(COMMAND ${CMAKE_COMMAND} -E env
  "LD_LIBRARY_PATH=${LIBRARY_DIR}" "FAKE_CUDA_STAGE=${STAGE}" "${PROBE}"
  RESULT_VARIABLE status OUTPUT_VARIABLE output ERROR_VARIABLE errors)
set(codes 0 6 3 4 5)
set(messages "OK drv=13000 run=13000 ndev=1 lib=libcudart.so"
  "DEVICE_COUNT_FAIL drv=13000 run=13000"
  "CTX_INIT_FAIL drv=13000 run=13000 ndev=1"
  "GET_POOL_FAIL" "SET_ATTR_FAIL")
list(GET codes ${STAGE} expected_code)
list(GET messages ${STAGE} expected_message)
if(NOT STAGE EQUAL 0)
  string(APPEND expected_message " err=801(operation not supported) lib=libcudart.so")
endif()
if(NOT status EQUAL expected_code OR NOT output STREQUAL "${expected_message}\n")
  message(FATAL_ERROR "CUDA stage ${STAGE}: status=${status}, output=${output}, stderr=${errors}")
endif()
