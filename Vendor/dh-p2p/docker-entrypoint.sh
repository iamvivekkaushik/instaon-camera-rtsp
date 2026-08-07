#!/bin/sh
set -e

# Dokku / docker: build argv from env when no CLI args are passed.
# Example:
#   dokku config:set instaon-relay \
#     SERIAL=2009011801001104 RELAY=1 CLOUD=instaon AUTH_TYPE=0
if [ "$#" -eq 0 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
  if [ -z "${SERIAL:-}" ]; then
    if [ "$#" -gt 0 ]; then
      exec dh-p2p "$@"
    fi
    echo "SERIAL is required (dokku config:set SERIAL=... or pass CLI args)" >&2
    exit 2
  fi

  set --
  if [ "${RELAY:-0}" = "1" ] || [ "${RELAY:-}" = "true" ]; then
    set -- "$@" --relay
  fi
  set -- "$@" -c "${CLOUD:-instaon}"
  set -- "$@" -t "${AUTH_TYPE:-0}"
  if [ -n "${USERNAME:-}" ] && [ -n "${PASSWORD:-}" ]; then
    set -- "$@" -u "$USERNAME" --password "$PASSWORD"
  fi
  set -- "$@" -p "${BIND:-0.0.0.0:1554:554}"
  set -- "$@" "$SERIAL"
fi

# Default bind is 127.0.0.1, which is unreachable from outside the container.
has_port=0
for arg in "$@"; do
  case "$arg" in
    -p|--port|-p=*|--port=*)
      has_port=1
      break
      ;;
  esac
done

if [ "$has_port" -eq 0 ]; then
  set -- -p "0.0.0.0:1554:554" "$@"
fi

echo "Starting: dh-p2p $*"
exec dh-p2p "$@"
