#!/usr/bin/env bash
# Build a Wine prefix with Fork installed and the Linux compatibility fixes applied.
# Runs during `docker build`. The finished prefix is copied to a volume on first launch.
set -euo pipefail

FORK_VERSION="${FORK_VERSION:-2.16.1}"
WINEPREFIX="${WINEPREFIX:-/opt/wine-fork}"
export WINEPREFIX WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all}"
export WINETRICKS_DOWNLOADER="${WINETRICKS_DOWNLOADER:-curl}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FORK_URL="https://cdn.fork.dev/win/Fork-${FORK_VERSION}.exe"
FORK_INSTALLER="/tmp/Fork-${FORK_VERSION}.exe"

cd /tmp
echo "=== Wine $(wine --version) / Fork ${FORK_VERSION} ==="
echo "Prefix: ${WINEPREFIX}"

echo "=== Creating Wine prefix ==="
# Mono and Gecko are already in the image, so this does not open an installer.
wineboot -u
wineserver -k || true

echo "=== Windows 10 mode and fonts ==="
xvfb-run -a winetricks -q win10 corefonts tahoma consolas
wineserver -k || true

# Fork's WPF UI asks for Segoe UI, which cannot be redistributed. Tahoma is close enough.
wine reg add 'HKCU\Software\Wine\Fonts\Replacements' /v 'Segoe UI' /t REG_SZ /d 'Tahoma' /f
wine reg add 'HKCU\Software\Wine\Fonts\Replacements' /v 'Segoe UI Semibold' /t REG_SZ /d 'Tahoma' /f
wine reg add 'HKCU\Software\Wine\Fonts\Replacements' /v 'Segoe UI Light' /t REG_SZ /d 'Tahoma' /f

# MIT-SHM does not work across the Docker/X11 boundary and produces a black window.
wine reg add 'HKCU\Software\Wine\X11 Driver' /v UseXShm /t REG_SZ /d N /f
wine reg add 'HKCU\SOFTWARE\Microsoft\Avalon.Graphics' /v DisableHWAcceleration /t REG_DWORD /d 1 /f
wineserver -k || true

echo "=== Installing .NET Framework 4.7.2 ==="
if ! xvfb-run -a winetricks -q dotnet472; then
  echo "winetricks dotnet472 failed; trying the Microsoft installer directly"
  curl -fL --retry 3 -o /tmp/ndp472.exe \
    "https://download.visualstudio.microsoft.com/download/pr/158dce74-251c-4af3-b8cc-4608621341f8/9c1e178a11f55478e2112714a3897c1a/ndp472-kb4054530-x86-x64-allos-enu.exe"
  xvfb-run -a wine /tmp/ndp472.exe /q /norestart
  rm -f /tmp/ndp472.exe
fi
wineserver -k || true

RELEASE="$(wine reg query 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full' /v Release | awk '/Release/{print $3}')"
echo ".NET Release registry value: ${RELEASE:-missing}"
if [[ -z "${RELEASE}" ]]; then
  echo "ERROR: .NET Framework 4.x was not registered" >&2
  exit 1
fi

echo "=== Installing Fork ${FORK_VERSION} ==="
curl -fL --retry 3 -o "${FORK_INSTALLER}" "${FORK_URL}"
xvfb-run -a wine "${FORK_INSTALLER}" --silent
wineserver -k || true
rm -f "${FORK_INSTALLER}"

FORK_DIR="${WINEPREFIX}/drive_c/users/${USER}/AppData/Local/Fork/current"
if [[ ! -f "${FORK_DIR}/Fork.exe" ]]; then
  FOUND="$(find "${WINEPREFIX}/drive_c/users/${USER}/AppData/Local/Fork" -name Fork.exe -print -quit || true)"
  if [[ -z "${FOUND}" ]]; then
    echo "ERROR: Fork.exe was not installed" >&2
    find "${WINEPREFIX}/drive_c/users" -iname '*fork*' -print >&2 || true
    exit 1
  fi
  FORK_DIR="$(dirname "${FOUND}")"
fi
echo "Fork.exe: ${FORK_DIR}/Fork.exe"

# Do not copy WinRT .winmd files next to Fork.exe. WPF treats every .dll in
# that folder as a .NET assembly; names like Windows.Foundation.UniversalApiContract
# are invalid and crash window creation with FileLoadException 0x80131047.
# Theme WinRT calls are already stubbed by patch_fork.py.

echo "=== NaturalLanguage6 stub (WPF spell-check P/Invoke) ==="
NL_TMP="$(mktemp -d)"
cat > "${NL_TMP}/nl6stub.c" << 'EOF'
#include <windows.h>
BOOL WINAPI DllMain(HINSTANCE h, DWORD r, LPVOID p) { return TRUE; }
__declspec(dllexport) HRESULT WINAPI NlLoad(void) { return S_OK; }
__declspec(dllexport) void    WINAPI NlUnload(void) { }
__declspec(dllexport) HRESULT WINAPI NlGetClassObject(void *a, void *b, void *c) { return E_NOINTERFACE; }
__declspec(dllexport) HRESULT WINAPI NlCreateHyphenator(void *a, void **b) { if (b) *b = NULL; return E_NOINTERFACE; }
__declspec(dllexport) HRESULT WINAPI NlDestroyHyphenator(void *a) { return S_OK; }
__declspec(dllexport) HRESULT WINAPI NlHyphenate(void *a, void *b, int c, int d, void *e) { return S_OK; }
EOF
x86_64-w64-mingw32-gcc -shared -o "${NL_TMP}/NaturalLanguage6.dll" "${NL_TMP}/nl6stub.c" -Wl,--kill-at
# Keep the stub out of the app folder. WPF probes every .dll there as a
# managed assembly; a native stub makes AssemblyName throw 0x80131047.
cp "${NL_TMP}/NaturalLanguage6.dll" "${WINEPREFIX}/drive_c/windows/system32/"
MONO_LIB="${WINEPREFIX}/drive_c/windows/mono/mono-2.0/lib/x86_64"
if [[ -d "${MONO_LIB}" ]]; then
  cp "${NL_TMP}/NaturalLanguage6.dll" "${MONO_LIB}/"
fi
rm -rf "${NL_TMP}"
wine reg add 'HKCU\Software\Wine\DllOverrides' /v NaturalLanguage6 /t REG_SZ /d native /f
wineserver -k || true

PF_CONFIG_BODY='<?xml version="1.0" encoding="utf-8"?>
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
</configuration>'
mapfile -t PF_CONFIGS < <(find "${WINEPREFIX}" /opt/wine-staging/share/wine/mono -name PresentationFramework.dll.config 2>/dev/null || true)
if [[ ${#PF_CONFIGS[@]} -eq 0 ]]; then
  echo "WARNING: PresentationFramework.dll.config not found" >&2
else
  for PF_CONFIG in "${PF_CONFIGS[@]}"; do
    printf '%s\n' "${PF_CONFIG_BODY}" > "${PF_CONFIG}"
    echo "Patched Mono DLL map: ${PF_CONFIG}"
  done
fi

echo "=== Patching Fork.exe ==="
python3 "${SCRIPT_DIR}/patch_fork.py" "${FORK_DIR}/Fork.exe"

CANONICAL_DIR="${WINEPREFIX}/drive_c/users/${USER}/AppData/Local/Fork/current"
if [[ "${FORK_DIR}" != "${CANONICAL_DIR}" ]]; then
  ln -sfn "${FORK_DIR}" "${CANONICAL_DIR}"
  FORK_DIR="${CANONICAL_DIR}"
fi

# Velopack replaces the patched exe if an update is applied. The pinned build is the one these fixes match.
UPDATE_EXE="$(dirname "${FORK_DIR}")/Update.exe"
if [[ -f "${UPDATE_EXE}" ]]; then
  mv "${UPDATE_EXE}" "${UPDATE_EXE}.disabled"
  echo "Disabled Velopack updater: ${UPDATE_EXE}"
fi

echo "${FORK_VERSION}" > "${WINEPREFIX}/.fork-version"
wineserver -k || true
echo "=== Prefix ready ==="
