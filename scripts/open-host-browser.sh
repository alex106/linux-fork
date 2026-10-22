#!/bin/bash
# Wine launches this as xdg-open when Fork creates a pull request.
# The container has no browser, so the host desktop opens the page.
set -euo pipefail

url=""
for arg in "$@"; do
  case "${arg}" in
    http://*|https://*|mailto:*) url="${arg}" ;;
  esac
done
if [[ -z "${url}" ]]; then
  echo "xdg-open: no http(s) or mailto URL in: $*" >&2
  exit 1
fi

uid="$(id -u)"
bus="/run/user/${uid}/bus"
if [[ ! -S "${bus}" ]]; then
  echo "xdg-open: desktop session bus ${bus} is not available" >&2
  exit 1
fi
export DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}"

exec python3 - "${url}" << 'PY'
import sys
import dbus

url = sys.argv[1]
bus = dbus.SessionBus()
portal = bus.get_object(
    "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop"
)
opened = dbus.Interface(portal, "org.freedesktop.portal.OpenURI").OpenURI(
    "", url, {}
)
print(opened)
PY
