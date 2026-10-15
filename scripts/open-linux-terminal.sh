#!/usr/bin/env bash
# Open a real X11 terminal in the repo directory. Called from Wine via
# `start /unix` when Fork's Console button runs fork-linux-terminal.cmd.
set -euo pipefail
dir="${1:-}"
if [[ -z "${dir}" || ! -d "${dir}" ]]; then
  dir="${HOME:-/tmp}"
fi
export DISPLAY="${DISPLAY:-:0}"
cd "${dir}"
exec xterm -ls -fa Monospace -fs 11 -title "Fork: ${dir}" -e /bin/bash
