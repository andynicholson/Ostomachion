# Copyright (c) 2026
# SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0

zephyr_library_sources_ifdef(CONFIG_FFT_ACCEL fft_accel.c)
