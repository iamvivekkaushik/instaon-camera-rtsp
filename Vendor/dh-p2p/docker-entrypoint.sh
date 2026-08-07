#!/bin/sh
set -e

# Default bind is 127.0.0.1, which is unreachable from outside the container.
# If the caller did not pass -p/--port, listen on all interfaces.
has_port=0
for arg in "$@"; do
  case "$arg" in
    -p|--port|-p=*|--port=*)
      has_port=1
      break
      ;;
  esac
done

if [ "$has_port" -eq 0 ] && [ "$#" -gt 0 ] && [ "$1" != "--help" ] && [ "$1" != "-h" ]; then
  set -- -p "0.0.0.0:1554:554" "$@"
fi

exec dh-p2p "$@"
