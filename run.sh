#!/usr/bin/env bash
# Build the image if needed and open Fork on this desktop.
set -euo pipefail
cd "$(dirname "$0")"

export DISPLAY="${DISPLAY:-:0}"
export HOST_UID="$(id -u)"
export HOST_GID="$(id -g)"
export HOST_HOME="${HOST_HOME:-$HOME}"

# Fork has to open a window on this machine. Docker Desktop runs containers
# inside a VM, and that VM cannot use the host X11 socket. The host engine can.
if [[ -S /var/run/docker.sock ]]; then
  export DOCKER_HOST=unix:///var/run/docker.sock
fi

if [[ ! -S "/tmp/.X11-unix/X${DISPLAY#:}" ]]; then
  echo "No X11 socket for DISPLAY=${DISPLAY}." >&2
  echo "This session needs XWayland (or Xorg). On a Wayland-only session, log in with XWayland enabled." >&2
  exit 1
fi

exec docker compose up --build --abort-on-container-exit --remove-orphans
