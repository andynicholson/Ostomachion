#!/usr/bin/env bash
# gen_release_artifacts.sh — collect and stage release/v<VERSION>/ artifacts
# Copyright (c) 2026  SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
#
# Run this script after a successful 'make fpga-synth' to stage all required
# certification artifacts into release/<version>/ for client delivery.
#
# Usage:
#   bash scripts/gen_release_artifacts.sh [VERSION]
#
# If VERSION is omitted, it is derived from the latest git tag (e.g. v1.0.0).
# The release directory is created under the project root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJ_ROOT/build/xem7310"

# ── Determine version ────────────────────────────────────────────────────────
if [[ $# -ge 1 ]]; then
    VERSION="$1"
else
    VERSION="$(git -C "$PROJ_ROOT" describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0-dev")"
fi
RELEASE_DIR="$PROJ_ROOT/release/$VERSION"

echo "=== Staging release artifacts for $VERSION ==="
echo "    Source : $BUILD_DIR"
echo "    Target : $RELEASE_DIR"

mkdir -p "$RELEASE_DIR"

# ── Required build outputs ───────────────────────────────────────────────────
required_files=(
    "$BUILD_DIR/ostomachion_xem7310.bit"
    "$BUILD_DIR/ostomachion_xem7310.mcs"
    "$BUILD_DIR/timing_summary.rpt"
    "$BUILD_DIR/utilization.rpt"
    "$BUILD_DIR/drc.rpt"
    "$BUILD_DIR/build_id.txt"
)

for f in "${required_files[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: Required file not found: $f"
        echo "ERROR: Run 'make fpga-synth' first."
        exit 1
    fi
    cp "$f" "$RELEASE_DIR/"
    echo "  Copied: $(basename "$f")"
done

# ── Generate memory map from firmware ELF (if available) ────────────────────
FIRMWARE_ELF=""
for build_d in "$PROJ_ROOT/build_zephyr_fpga" "$PROJ_ROOT/build_zephyr_accel_test"; do
    if [[ -f "$build_d/zephyr/zephyr.elf" ]]; then
        FIRMWARE_ELF="$build_d/zephyr/zephyr.elf"
        break
    fi
done

if [[ -n "$FIRMWARE_ELF" ]]; then
    echo "=== Generating firmware memory map from $FIRMWARE_ELF ==="
    NM_CMD=""
    for nm in riscv64-unknown-elf-nm riscv64-linux-gnu-nm; do
        if command -v "$nm" &>/dev/null; then
            NM_CMD="$nm"
            break
        fi
    done
    if [[ -n "$NM_CMD" ]]; then
        "$NM_CMD" --size-sort --print-size "$FIRMWARE_ELF" \
            > "$RELEASE_DIR/memory_map.txt" 2>&1
        echo "  Generated: memory_map.txt ($(wc -l < "$RELEASE_DIR/memory_map.txt") symbols)"
    else
        echo "  WARN: No RISC-V nm found — memory_map.txt not generated"
    fi
else
    echo "  INFO: No firmware ELF found — run 'make zephyr-fpga' to generate"
fi

# ── Write release manifest ────────────────────────────────────────────────────
BUILD_ID="$(cat "$BUILD_DIR/build_id.txt" 2>/dev/null || echo "unknown")"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$RELEASE_DIR/RELEASE.txt" << EOF
Ostomachion Accelerator Platform — Release $VERSION
====================================================
Build ID  : $BUILD_ID
Generated : $TIMESTAMP
NEORV32   : v1.11.6 (submodule, see .gitmodules)

Contents
--------
ostomachion_xem7310.bit  — FPGA bitstream (Opal Kelly XEM7310-A200)
ostomachion_xem7310.mcs  — SPI flash image (program with 'make fpga-flash')
timing_summary.rpt       — Vivado timing closure report (WNS/WHS must be >= 0)
utilization.rpt          — FPGA resource utilisation
drc.rpt                  — Design Rule Check (must show 0 errors)
build_id.txt             — Version + git hash + build timestamp
memory_map.txt           — Firmware symbol table sorted by size (if available)

Acceptance
----------
See docs/acceptance_test_procedure.md for the 10-point client acceptance test.

Flash Programming
-----------------
  make fpga-synth   # build bitstream + MCS
  make fpga-flash   # program on-board Quad-SPI flash (persistent boot)
  make fpga-fw      # upload Zephyr firmware via UART bootloader
EOF

echo ""
echo "=== Release artifacts staged: $RELEASE_DIR ==="
echo "=== Contents:"
ls -lh "$RELEASE_DIR"
echo ""
echo "Next step: tag the release and commit the release/ directory:"
echo "  git add release/$VERSION"
echo "  git commit -m 'release: add $VERSION artifacts'"
echo "  git tag -a $VERSION -m 'Ostomachion $VERSION release'"
echo "  git push --follow-tags"
