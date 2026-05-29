# Copyright (c) 2026
# SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0

zephyr_library_sources_ifdef(CONFIG_WDT_NEORV32 wdt_neorv32.c)
