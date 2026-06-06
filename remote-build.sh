#!/bin/bash
# remote-build.sh — drive an Ostomachion build/test stage on the remote builder
# Copyright (c) 2026  SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
#
# The remote builder (andy@192.168.0.21) holds the full toolchain — Vivado
# 2025.1, the FrontPanel SDK, the Zephyr SDK + west workspace, and (for the
# `hil` stage) a connected XEM7310-A200.  This wrapper sources the dev env
# there and dispatches one stage, so the same command works from any dev box.
#
# Usage:
#   ./remote-build.sh [stage]
#
# Stages (fastest-fail first — this is also the recommended verification order):
#   math   ctest on host_tests        — pure filter-mask synthesis, no GHDL/Vivado
#   sim    make test-zephyr           — GHDL co-sim (incl. the filter-mask ZTEST)
#   synth  make fpga-synth            — Vivado batch: synth + impl + bitstream
#   check  make fpga-check            — WNS/WHS/DRC + utilisation gates
#   hil    make fpga-program + test-accel-hw — program the board, run HIL ZTESTs
#   all    math → sim → synth → check  (HIL is explicit; it needs the board)
#
# Override the remote host / path with OSTO_REMOTE and OSTO_REMOTE_DIR.

set -euo pipefail

STAGE="${1:-all}"
REMOTE="${OSTO_REMOTE:-andy@192.168.0.21}"
REMOTE_DIR="${OSTO_REMOTE_DIR:-src/neorv32_ghdl/ostomachion}"

# Build the remote command for the requested stage.  init_dev_env.sh must be
# sourced in the SAME shell as the build (it exports ZEPHYR_BASE, the Vivado
# PATH, FRONTPANEL_DIR, and activates the venv).
case "$STAGE" in
  math)
    REMOTE_CMD='cmake -S host_tests -B build/host_tests && cmake --build build/host_tests && ctest --test-dir build/host_tests --output-on-failure'
    ;;
  sim)
    REMOTE_CMD='make test-zephyr'
    ;;
  synth)
    REMOTE_CMD='make fpga-synth'
    ;;
  check)
    REMOTE_CMD='make fpga-check'
    ;;
  hil)
    REMOTE_CMD='make fpga-program && make test-accel-hw'
    ;;
  all)
    REMOTE_CMD='cmake -S host_tests -B build/host_tests && cmake --build build/host_tests && ctest --test-dir build/host_tests --output-on-failure && make test-zephyr && make fpga-synth && make fpga-check'
    ;;
  *)
    echo "ERROR: unknown stage '$STAGE'" >&2
    echo "Valid stages: math sim synth check hil all" >&2
    exit 2
    ;;
esac

echo "=== remote-build.sh: stage '$STAGE' on $REMOTE:$REMOTE_DIR ==="
exec ssh "$REMOTE" "cd '$REMOTE_DIR' && source scripts/init_dev_env.sh && $REMOTE_CMD"
