#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)
#
# Regenerate the architecture diagram PNGs (light + dark) from the
# D2 source file.
#
# Prerequisites (one-time):
#   curl -fsSL https://d2lang.com/install.sh | sh -s --
#
# Or via package manager:
#   brew install d2  (macOS)
#   See https://d2lang.com/releases/intro for other platforms

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT="${SCRIPT_DIR}/blktests-ci-architecture.d2"
OUT_LIGHT="${SCRIPT_DIR}/blktests-ci-architecture-light.png"
OUT_DARK="${SCRIPT_DIR}/blktests-ci-architecture-dark.png"

if ! command -v d2 &>/dev/null; then
    echo "Error: d2 not found." >&2
    echo "Install it with:" >&2
    echo "  curl -fsSL https://d2lang.com/install.sh | sh -s --" >&2
    exit 1
fi

echo "Exporting light mode PNG..."
d2 --theme 0 --pad 40 "${INPUT}" "${OUT_LIGHT}"

echo "Exporting dark mode PNG..."
d2 --theme 200 --pad 40 "${INPUT}" "${OUT_DARK}"

echo "Done:"
echo "  ${OUT_LIGHT}"
echo "  ${OUT_DARK}"
