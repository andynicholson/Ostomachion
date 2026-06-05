# host_tests/CMakeLists.txt — off-target (host) unit tests
# Copyright (c) 2026  SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
#
# These tests have NO Zephyr / GHDL / Vivado dependency.  They compile with the
# host system compiler and exercise the pure, hardware-independent firmware math
# (currently the spectral filter-mask synthesis in
# zephyr_app/include/ostomachion/filter_mask.hpp).
#
# Build & run:
#   cmake -S host_tests -B build/host_tests
#   cmake --build build/host_tests
#   ctest --test-dir build/host_tests --output-on-failure
#
# remote-build.sh "math" stage runs:  ctest --test-dir build/host_tests

cmake_minimum_required(VERSION 3.16)
project(ostomachion_host_tests CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

enable_testing()

# The filter math header lives under the Zephyr app include tree; add it so the
# host test sees the exact same source the on-target HAL uses.
set(OSTO_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/../zephyr_app/include")

add_executable(test_filter_mask test_filter_mask.cpp)
target_include_directories(test_filter_mask PRIVATE "${OSTO_INCLUDE}")
target_compile_options(test_filter_mask PRIVATE -Wall -Wextra -Werror)

add_test(NAME filter_mask COMMAND test_filter_mask)
set_tests_properties(filter_mask PROPERTIES
    PASS_REGULAR_EXPRESSION "PROJECT EXECUTION SUCCESSFUL")
