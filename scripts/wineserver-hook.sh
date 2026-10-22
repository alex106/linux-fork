#!/bin/sh
# Wine starts this program whenever it wants wineserver. Load the nested
# directory watch helper, then run the real server. The helper is 64-bit, so
# it must not be preloaded into Wine's 32-bit processes.
case ":${LD_PRELOAD:-}:" in
  *:/opt/fork/libfork-dirwatch.so:*) ;;
  *)
    LD_PRELOAD="/opt/fork/libfork-dirwatch.so${LD_PRELOAD:+:$LD_PRELOAD}"
    export LD_PRELOAD
    ;;
esac
exec /opt/wine-staging/bin/wineserver.real "$@"
