#!/usr/bin/env bash
# Desktop entry point. Opens a terminal so image build and Wine startup stay visible.
set -u

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "${repo}"

if [[ -z "${FORK_DESKTOP_TERMINAL:-}" ]]; then
  export FORK_DESKTOP_TERMINAL=1
  quoted="$(printf '%q' "${repo}")"
  if command -v gnome-terminal >/dev/null 2>&1; then
    exec gnome-terminal --title=Fork --wait -- bash -lc "cd ${quoted} && exec ./scripts/desktop-launch.sh"
  fi
  if command -v x-terminal-emulator >/dev/null 2>&1; then
    exec x-terminal-emulator -T Fork -e bash -lc "cd ${quoted} && exec ./scripts/desktop-launch.sh"
  fi
fi

./run.sh
status=$?
if [[ "${status}" -ne 0 ]]; then
  echo
  echo "Fork exited with status ${status}."
  read -r -p "Press Enter to close... "
fi
exit "${status}"
