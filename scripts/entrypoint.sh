#!/usr/bin/env bash
# Start Fork on the host display.
# The Wine prefix lives in the /data volume. The first launch installs
# .NET Framework and Fork there, so a license survives later image rebuilds.
set -euo pipefail

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
HOST_HOME="${HOST_HOME:-}"
if [[ -z "${HOST_HOME}" || ! -d "${HOST_HOME}" ]]; then
  echo "HOST_HOME must be the host account's home directory (got '${HOST_HOME:-unset}')." >&2
  echo "Start the container with ./run.sh so it follows the user who launched it." >&2
  exit 1
fi
export WINEPREFIX="${WINEPREFIX:-/data/prefix}"
export WINEARCH="${WINEARCH:-win64}"
export WINEDEBUG="${WINEDEBUG:-err+all,fixme-all}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-NaturalLanguage6=n}"
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
export HOME=/home/fork
export USER=fork
export LOGNAME=fork
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-fork}"

FORK_EXE="${WINEPREFIX}/drive_c/users/fork/AppData/Local/Fork/current/Fork.exe"
LOG_DIR=/data/logs

if [[ "$(id -u)" -eq 0 ]]; then
  if [[ "$(id -u fork)" != "${HOST_UID}" ]]; then
    usermod -o -u "${HOST_UID}" fork
  fi
  if [[ "$(id -g fork)" != "${HOST_GID}" ]]; then
    groupmod -o -g "${HOST_GID}" fork
  fi

  mkdir -p "${WINEPREFIX}" "${LOG_DIR}" "${XDG_RUNTIME_DIR}"
  chown fork:fork /data /home/fork "${XDG_RUNTIME_DIR}"
  if [[ ! -f "${WINEPREFIX}/.fork-version" ]]; then
    chown -R fork:fork /data /home/fork
  fi
  # Fork's "Create Pull Request" asks winebrowser to open a URL. winebrowser
  # runs xdg-open, which this image does not ship. Point that name at the
  # host desktop instead.
  if [[ -f /opt/fork/open-host-browser.sh ]]; then
    cp -f /opt/fork/open-host-browser.sh /usr/local/bin/xdg-open
    chmod 755 /usr/local/bin/xdg-open
  fi
  if [[ -d /opt/wine-staging/share/wine/winmd && ! -d /opt/wine-staging/share/wine/winmd.disabled ]]; then
    mv /opt/wine-staging/share/wine/winmd /opt/wine-staging/share/wine/winmd.disabled
  fi
  PF_CONFIG=/opt/wine-staging/share/wine/mono/wine-mono-11.3.0/lib/mono/gac/PresentationFramework/4.0.0.0__31bf3856ad364e35/PresentationFramework.dll.config
  if [[ -f "${PF_CONFIG}" ]]; then
    cat > "${PF_CONFIG}" << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
    <dllmap dll="PresentationNative_cor3.dll" target="$mono_libdir\x86\PresentationNative_cor3.dll" os="windows" cpu="x86">
        <dllentry dll="NaturalLanguage6" name="NlLoad" target="NlLoad"/>
        <dllentry dll="NaturalLanguage6" name="NlUnload" target="NlUnload"/>
        <dllentry dll="NaturalLanguage6" name="NlGetClassObject" target="NlGetClassObject"/>
        <dllentry dll="NaturalLanguage6" name="NlCreateHyphenator" target="NlCreateHyphenator"/>
        <dllentry dll="NaturalLanguage6" name="NlDestroyHyphenator" target="NlDestroyHyphenator"/>
        <dllentry dll="NaturalLanguage6" name="NlHyphenate" target="NlHyphenate"/>
    </dllmap>
    <dllmap dll="PresentationNative_cor3.dll" target="$mono_libdir\x86_64\PresentationNative_cor3.dll" os="windows" cpu="x86-64">
        <dllentry dll="NaturalLanguage6" name="NlLoad" target="NlLoad"/>
        <dllentry dll="NaturalLanguage6" name="NlUnload" target="NlUnload"/>
        <dllentry dll="NaturalLanguage6" name="NlGetClassObject" target="NlGetClassObject"/>
        <dllentry dll="NaturalLanguage6" name="NlCreateHyphenator" target="NlCreateHyphenator"/>
        <dllentry dll="NaturalLanguage6" name="NlDestroyHyphenator" target="NlDestroyHyphenator"/>
        <dllentry dll="NaturalLanguage6" name="NlHyphenate" target="NlHyphenate"/>
    </dllmap>
</configuration>
EOF
  fi
  exec runuser --preserve-environment -u fork -- "$0" "$@"
fi

mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"

if [[ -z "${DISPLAY:-}" ]]; then
  echo "DISPLAY is not set. Start this container from a graphical session." >&2
  exit 1
fi

if [[ ! -S "/tmp/.X11-unix/X${DISPLAY#:}" ]]; then
  echo "X11 socket /tmp/.X11-unix/X${DISPLAY#:} is not available inside the container." >&2
  exit 1
fi

if [[ ! -f "${WINEPREFIX}/.fork-version" ]]; then
  if [[ "${WINEPREFIX}" != /data/prefix ]]; then
    echo "Refusing to reset unexpected WINEPREFIX=${WINEPREFIX}" >&2
    exit 1
  fi
  echo "Installing Fork. The first run downloads .NET Framework and usually takes 20-40 minutes."
  rm -rf "${WINEPREFIX}"
  mkdir -p "${WINEPREFIX}"
  WINEDEBUG=-all /opt/fork/install-fork.sh
fi

printf '%s\n' "${HOST_HOME}" > /opt/fork/host-home

WINE_HOME="${WINEPREFIX}/drive_c/users/fork"
mkdir -p "${WINE_HOME}"
{
  if [[ -f "${HOST_HOME}/.gitconfig" ]]; then
    cat << EOF
[include]
	path = Z:${HOST_HOME}/.gitconfig
EOF
  fi
  cat << 'EOF'
[core]
	autocrlf = false
	eol = lf
	filemode = false
	fscache = false
[credential]
	helper =
	helper = linux
EOF
} > "${WINE_HOME}/.gitconfig"
if [[ -d "${HOST_HOME}/.ssh" ]]; then
  ln -sfn "${HOST_HOME}/.ssh" "${WINE_HOME}/.ssh"
fi

if [[ ! -f "${FORK_EXE}" ]]; then
  echo "Fork.exe is missing at ${FORK_EXE}" >&2
  exit 1
fi

FORK_DIR="$(dirname "${FORK_EXE}")"
# Files that make WPF's XAML loader throw FileLoadException 0x80131047.
shopt -s nullglob
for leftover in "${FORK_DIR}"/Windows.*.dll; do
  rm -f "${leftover}"
done
shopt -u nullglob
rm -f "${FORK_DIR}/NaturalLanguage6.dll" \
      "${FORK_DIR}/System.Runtime.WindowsRuntime.dll"
# WinUI toast stack pulls invalid WinRT assembly names into WPF.
if [[ -f "${FORK_DIR}/CommunityToolkit.WinUI.Notifications.dll" ]]; then
  mv -f "${FORK_DIR}/CommunityToolkit.WinUI.Notifications.dll" \
        "${FORK_DIR}/CommunityToolkit.WinUI.Notifications.dll.disabled"
fi
if [[ -f "${FORK_EXE}.original" ]]; then
  cp -f "${FORK_EXE}.original" "${FORK_EXE}"
fi
python3 /opt/fork/patch_fork.py "${FORK_EXE}"

SETTINGS="${WINEPREFIX}/drive_c/users/fork/AppData/Local/Fork/settings.json"
if [[ -f "${SETTINGS}" ]]; then
  python3 - "${SETTINGS}" << 'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["ApplicationUpdateType"] = 0
data["FollowSystemTheme"] = False
data["DisableHardwareAcceleration"] = True
data["GitInstancePath"] = r"C:\users\fork\AppData\Local\Fork\gitInstance\2.50.1\bin\git.exe"
data["ShellTool"] = {
    "Type": "Custom",
    "DisplayName": "Linux Terminal",
    "ApplicationPath": r"C:\windows\system32\fork-linux-terminal.exe",
    "Arguments": "",
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
fi

cp -f /opt/fork/fork-linux-terminal.cmd \
  "${WINEPREFIX}/drive_c/windows/system32/fork-linux-terminal.cmd"
cp -f /opt/fork/fork-linux-terminal.exe \
  "${WINEPREFIX}/drive_c/windows/system32/fork-linux-terminal.exe"

# PortableGit's default helper is Git Credential Manager. CredEnumerate
# fails under Wine with ERROR_INVALID_FLAGS (0x3ec), so clones never see
# a real token. "linux" is git-credential-linux.exe, which asks host gh.
GIT_MINGW="${WINEPREFIX}/drive_c/users/fork/AppData/Local/Fork/gitInstance/2.50.1/mingw64"
if [[ -d "${GIT_MINGW}/bin" ]]; then
  cp -f /opt/fork/git-credential-linux.exe "${GIT_MINGW}/bin/git-credential-linux.exe"
fi
if [[ -d "${GIT_MINGW}/libexec/git-core" ]]; then
  cp -f /opt/fork/git-credential-linux.exe "${GIT_MINGW}/libexec/git-core/git-credential-linux.exe"
fi
GIT_ETC="${WINEPREFIX}/drive_c/users/fork/AppData/Local/Fork/gitInstance/2.50.1/etc/gitconfig"
if [[ -f "${GIT_ETC}" ]]; then
  sed -i 's/^[[:space:]]*helper = manager$/	helper =/' "${GIT_ETC}"
fi

# Console / Open in Git Bash start PortableGit's bash.exe (or git-bash.exe),
# not the custom ShellTool. Keep the real MSYS bash for Git hooks.
GIT_BIN="${WINEPREFIX}/drive_c/users/fork/AppData/Local/Fork/gitInstance/2.50.1/bin"
GIT_ROOT="$(dirname "${GIT_BIN}")"
if [[ -f "${GIT_BIN}/bash.exe" ]]; then
  if [[ ! -f "${GIT_BIN}/bash-msys.exe" ]]; then
    mv -f "${GIT_BIN}/bash.exe" "${GIT_BIN}/bash-msys.exe"
  fi
  cp -f /opt/fork/fork-linux-terminal.exe "${GIT_BIN}/bash.exe"
fi
if [[ -f "${GIT_ROOT}/git-bash.exe" && ! -f "${GIT_ROOT}/git-bash.exe.msys" ]]; then
  mv -f "${GIT_ROOT}/git-bash.exe" "${GIT_ROOT}/git-bash.exe.msys"
fi
if [[ -d "${GIT_ROOT}" ]]; then
  cp -f /opt/fork/fork-linux-terminal.exe "${GIT_ROOT}/git-bash.exe"
fi

if [[ -n "${FORK_REPO:-}" && -x /opt/fork/install-desktop-shortcut.sh ]]; then
  FORK_EXE="${FORK_EXE}" /opt/fork/install-desktop-shortcut.sh \
    || echo "Desktop shortcut was not installed." >&2
fi

# MIT-SHM cannot share pixels from a Docker IPC namespace to the host X server.
wine reg add 'HKCU\Software\Wine\X11 Driver' /v UseXShm /t REG_SZ /d N /f >/dev/null
wine reg add 'HKCU\SOFTWARE\Microsoft\Avalon.Graphics' /v DisableHWAcceleration /t REG_DWORD /d 1 /f >/dev/null
wineserver -k || true

mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/fork-$(date +%Y%m%d-%H%M%S).log"
echo "Launching Fork on DISPLAY=${DISPLAY}"
echo "Log: ${LOG_FILE}"
echo "Open repositories under ${HOST_HOME} (Wine drive Z:)."

cd "$(dirname "${FORK_EXE}")"
set +e
wine "${FORK_EXE}" "$@" > >(tee -a "${LOG_FILE}") 2>&1
EXIT_CODE=$?
set -e
if [[ "${EXIT_CODE}" -ne 0 ]]; then
  echo "Fork exited with code ${EXIT_CODE}. Last log lines:" >&2
  tail -30 "${LOG_FILE}" >&2 || true
fi
exit "${EXIT_CODE}"
