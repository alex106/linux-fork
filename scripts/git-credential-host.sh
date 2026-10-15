#!/usr/bin/env bash
# Git credential helper for Fork's Windows git. Speaks the helper protocol
# by calling the host user's `gh` login (home directory is mounted in).
action="${1:-get}"
infile="${2:-}"
outfile="${3:-}"

if [[ -z "${outfile}" ]]; then
  exit 0
fi
: > "${outfile}"

host_home=""
if [[ -f /opt/fork/host-home ]]; then
  host_home="$(head -1 /opt/fork/host-home)"
fi
if [[ -z "${host_home}" ]]; then
  host_home="${HOST_HOME:-}"
fi
if [[ -z "${host_home}" || ! -d "${host_home}" ]]; then
  echo "Fork could not find the host home directory for GitHub login." >&2
  exit 0
fi

export HOME="${host_home}"
export GH_CONFIG_DIR="${HOME}/.config/gh"
uid="$(stat -c %u "${host_home}" 2>/dev/null || echo 1000)"
if [[ -d "/run/user/${uid}" ]]; then
  export XDG_RUNTIME_DIR="/run/user/${uid}"
fi

if [[ ! -f "${infile}" ]]; then
  exit 0
fi

host="$(sed -n 's/^host=//p' "${infile}" | head -1)"
case "${host}" in
  github.com|*.github.com) ;;
  *) exit 0 ;;
esac

if ! command -v gh >/dev/null 2>&1; then
  echo "The gh command is not installed in the Fork container." >&2
  exit 0
fi

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  echo "No GitHub login on this machine. In a Linux terminal run: gh auth login" >&2
  echo "Sign in with the account that can access the repository, then clone again." >&2
  exit 0
fi

gh auth git-credential "${action}" < "${infile}" > "${outfile}"
