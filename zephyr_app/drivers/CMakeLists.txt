# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

zephyr_include_directories(${ZEPHYR_BASE}/drivers/spi)
zephyr_include_directories(${ZEPHYR_BASE}/drivers/i2c)
zephyr_include_directories(${CMAKE_CURRENT_SOURCE_DIR}/../include)

zephyr_library()

zephyr_library_sources_ifdef(CONFIG_SPI_NEORV32 spi/spi_neorv32.c)
zephyr_library_sources_ifdef(CONFIG_I2C_NEORV32 i2c/i2c_neorv32.c)
zephyr_library_sources_ifdef(CONFIG_WDT_NEORV32 wdt/wdt_neorv32.c)

add_subdirectory_ifdef(CONFIG_FFT_ACCEL accel)
