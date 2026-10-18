#!/usr/bin/env bash
# Put a Fork launcher on the host desktop. The icon is the one embedded in Fork.exe.
set -euo pipefail

HOST_HOME="${HOST_HOME:-${HOME:-}}"
FORK_REPO="${FORK_REPO:-}"
FORK_EXE="${FORK_EXE:-}"

if [[ -z "${HOST_HOME}" || ! -d "${HOST_HOME}" ]]; then
  echo "Desktop shortcut skipped: HOST_HOME is not a directory." >&2
  exit 0
fi
if [[ -z "${FORK_REPO}" || ! -x "${FORK_REPO}/run.sh" ]]; then
  echo "Desktop shortcut skipped: FORK_REPO does not contain run.sh." >&2
  exit 0
fi

desktop="${HOST_HOME}/Desktop"
if [[ -f "${HOST_HOME}/.config/user-dirs.dirs" ]]; then
  configured="$(sed -n 's/^XDG_DESKTOP_DIR=//p' "${HOST_HOME}/.config/user-dirs.dirs" | head -1 | tr -d '"')"
  configured="${configured//\$HOME/${HOST_HOME}}"
  if [[ -n "${configured}" ]]; then
    desktop="${configured}"
  fi
fi
mkdir -p "${desktop}" "${HOST_HOME}/.local/share/icons"

icon="${HOST_HOME}/.local/share/icons/fork.png"
script_dir="$(cd "$(dirname "$0")" && pwd)"
icon_source="${FORK_EXE}"
if [[ -n "${FORK_EXE}" && -f "${FORK_EXE}.original" ]]; then
  icon_source="${FORK_EXE}.original"
fi
if [[ -n "${icon_source}" && -f "${icon_source}" ]]; then
  python3 "${script_dir}/extract-fork-icon.py" "${icon_source}" "${icon}"
fi

cat > "${desktop}/Fork.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Fork
Comment=Open the Fork Git client
Exec=${FORK_REPO}/run.sh
Path=${FORK_REPO}
Icon=${icon}
Terminal=false
StartupNotify=true
Categories=Development;
EOF
chmod +x "${desktop}/Fork.desktop"

if command -v gio >/dev/null 2>&1; then
  gio set "${desktop}/Fork.desktop" metadata::trusted true >/dev/null 2>&1 || true
fi
echo "Desktop shortcut: ${desktop}/Fork.desktop"
