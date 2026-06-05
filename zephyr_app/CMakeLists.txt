# Copyright (c) 2026
# SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0

cmake_minimum_required(VERSION 3.20.0)

list(APPEND ZEPHYR_EXTRA_MODULES ${CMAKE_CURRENT_SOURCE_DIR})

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(ostomachion VERSION 0.1.0 LANGUAGES C CXX ASM)

target_include_directories(app PRIVATE include)

target_compile_options(app PRIVATE -Werror)

target_sources(app PRIVATE src/main.cpp)

# ZTest suites — only compiled when ZTEST is enabled
if(CONFIG_ZTEST)
  target_sources(app PRIVATE
    tests/test_spi.cpp
    tests/test_i2c.cpp
    tests/test_gpio.cpp
    # Hardware-independent filter-mask math: runs on the NEORV32 sim model.
    tests/test_filter_mask.cpp
  )
  if(CONFIG_WDT_NEORV32)
    target_sources(app PRIVATE tests/test_wdt.cpp)
  endif()
  if(CONFIG_FFT_ACCEL)
    target_sources(app PRIVATE tests/test_fft_accel.cpp)
  endif()
endif()

if(CONFIG_SHELL)
  target_sources(app PRIVATE src/test_runner.c)
  if(CONFIG_FFT_ACCEL)
    target_sources(app PRIVATE src/fft_shell.c)
  endif()
endif()

if(CONFIG_FFT_DEMO)
  target_sources(app PRIVATE src/fft_demo_main.c)
endif()
