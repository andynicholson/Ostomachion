#!/usr/bin/env bash
# Ostomachion — initialise shell environment for Zephyr + Ostomachion builds
# Copyright (c) 2026  SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Ostomachion-Commercial-1.0
#
# This script MUST be sourced (it activates a Python venv and exports vars).
#
#   cd /path/to/ostomachion
#   source scripts/init_dev_env.sh
#
#   make zephyr-fpga
#   make fpga-synth    # loads Vivado via settings script below
#
# Override defaults by exporting these before sourcing:
#   OSTOMACHION_ZEPHYR_VENV       default: ~/.zephyr-venv
#   OSTOMACHION_ZEPHYR_WORKSPACE  default: ~/src/zephyrproject  (contains zephyr/ + .west)
#   ZEPHYR_SDK_INSTALL_DIR        default: ~/zephyr-sdk-1.0.0
#   OSTOMACHION_VIVADO_SETTINGS   default: /tools/Xilinx/2025.1/Vivado/settings64.sh
#   FRONTPANEL_DIR                default: auto-detected from ~/OpalKelly/FrontPanel-*
#                                           (required for make fpga-synth, make uart-bridge)
#
# shellcheck shell=bash

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
	echo "ERROR: source this file; do not execute it." >&2
	echo "  cd /path/to/ostomachion && source scripts/init_dev_env.sh" >&2
	exit 1
fi

_OSTO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Defaults (match README.md “Getting started”) ───────────────────────────
: "${OSTOMACHION_ZEPHYR_VENV:=${HOME}/.zephyr-venv}"
: "${OSTOMACHION_ZEPHYR_WORKSPACE:=${HOME}/src/zephyrproject}"
: "${ZEPHYR_SDK_INSTALL_DIR:=${HOME}/zephyr-sdk-1.0.0}"
: "${OSTOMACHION_VIVADO_SETTINGS:=/tools/Xilinx/2025.1/Vivado/settings64.sh}"

# Auto-detect FrontPanel SDK root from ~/OpalKelly/FrontPanel-* if not already set.
# The glob matches any installed version/platform string; sort -V picks the newest
# when multiple versions are present.
if [[ -z "${FRONTPANEL_DIR:-}" ]]; then
	# Trailing slash restricts the glob to directories only, avoiding .tgz files.
	_fp_candidates=( "${HOME}/OpalKelly"/FrontPanel-*/ )
	if [[ -d "${_fp_candidates[-1]}" ]]; then
		FRONTPANEL_DIR="${_fp_candidates[-1]%/}"  # strip trailing slash
	fi
	unset _fp_candidates
fi

_ZEPHYR_BASE="${OSTOMACHION_ZEPHYR_WORKSPACE}/zephyr"

# ── Sanity checks ───────────────────────────────────────────────────────────
if [[ ! -d "${OSTOMACHION_ZEPHYR_VENV}" ]]; then
	echo "ERROR: Zephyr venv not found: ${OSTOMACHION_ZEPHYR_VENV}" >&2
	echo "Create it per README.md (python3 -m venv ~/.zephyr-venv && pip install west …)" >&2
	return 1 2>/dev/null || exit 1
fi

if [[ ! -f "${OSTOMACHION_ZEPHYR_VENV}/bin/activate" ]]; then
	echo "ERROR: Missing ${OSTOMACHION_ZEPHYR_VENV}/bin/activate" >&2
	return 1 2>/dev/null || exit 1
fi

if [[ ! -d "${_ZEPHYR_BASE}" ]]; then
	echo "ERROR: Zephyr tree not found: ${_ZEPHYR_BASE}" >&2
	echo "Expected a West workspace at ${OSTOMACHION_ZEPHYR_WORKSPACE} with a zephyr/ directory." >&2
	return 1 2>/dev/null || exit 1
fi

if [[ ! -d "${ZEPHYR_SDK_INSTALL_DIR}" ]]; then
	echo "WARN: Zephyr SDK dir not found: ${ZEPHYR_SDK_INSTALL_DIR}" >&2
	echo "Install SDK 1.0.0 per README.md; builds will fail until ZEPHYR_SDK_INSTALL_DIR is valid." >&2
fi

# ── Activate venv + exports ─────────────────────────────────────────────────
# shellcheck source=/dev/null
source "${OSTOMACHION_ZEPHYR_VENV}/bin/activate"

export ZEPHYR_BASE="${_ZEPHYR_BASE}"
export ZEPHYR_SDK_INSTALL_DIR
export OSTOMACHION_ROOT="${_OSTO_ROOT}"

# Prefer Zephyr’s west from the venv; workspace is the tree that contains .west + zephyr/
export WEST_TOPDIR="${OSTOMACHION_ZEPHYR_WORKSPACE}"

# Xilinx Vivado — puts vivado on PATH (required for make fpga-synth / fpga-flash)
_VIVADO_ENV_OK=0
if [[ -f "${OSTOMACHION_VIVADO_SETTINGS}" ]]; then
	# shellcheck source=/dev/null
	source "${OSTOMACHION_VIVADO_SETTINGS}"
	_VIVADO_ENV_OK=1
else
	echo "WARN: Vivado settings not found: ${OSTOMACHION_VIVADO_SETTINGS}" >&2
	echo "      make fpga-synth will fail until it exists or OSTOMACHION_VIVADO_SETTINGS is set." >&2
fi

# FrontPanel SDK — export if a valid directory was found or provided; warn otherwise.
# Non-fatal: Zephyr firmware builds do not need the SDK; only fpga-synth and uart-bridge do.
if [[ -n "${FRONTPANEL_DIR:-}" && -d "${FRONTPANEL_DIR}" ]]; then
	export FRONTPANEL_DIR
else
	echo "WARN: FrontPanel SDK not found (FRONTPANEL_DIR=${FRONTPANEL_DIR:-<unset>})" >&2
	echo "      Install from opalkelly.com and set FRONTPANEL_DIR to the SDK root." >&2
	echo "      make fpga-synth and make uart-bridge will fail without it." >&2
	unset FRONTPANEL_DIR
fi

echo "Ostomachion dev environment ready:"
echo "  OSTOMACHION_ROOT          = ${OSTOMACHION_ROOT}"
echo "  ZEPHYR_BASE               = ${ZEPHYR_BASE}"
echo "  ZEPHYR_SDK_INSTALL_DIR    = ${ZEPHYR_SDK_INSTALL_DIR}"
echo "  WEST_TOPDIR               = ${WEST_TOPDIR}"
echo "  venv                      = ${OSTOMACHION_ZEPHYR_VENV}"
if [[ "${_VIVADO_ENV_OK}" -eq 1 ]]; then
	echo "  Vivado (PATH)             = ${OSTOMACHION_VIVADO_SETTINGS} (sourced)"
else
	echo "  Vivado (PATH)             = (not configured)"
fi
if [[ -n "${FRONTPANEL_DIR:-}" ]]; then
	echo "  FRONTPANEL_DIR            = ${FRONTPANEL_DIR}"
else
	echo "  FRONTPANEL_DIR            = (not found — fpga-synth and uart-bridge will fail)"
fi
echo ""
echo "Next:  cd \"\${OSTOMACHION_ROOT}\" && make zephyr-fpga"
echo "       make fpga-synth"

unset _VIVADO_ENV_OK

unset _OSTO_ROOT _ZEPHYR_BASE
