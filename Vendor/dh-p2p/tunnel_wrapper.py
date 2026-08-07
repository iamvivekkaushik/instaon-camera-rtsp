#!/usr/bin/env python3
"""
CameraStreamer wrapper around khoanguyen-3fc/dh-p2p.

Differences from upstream main.py:
  - binds local RTSP on a high port (default 1554) so root is not required
  - prints CAMERA_STREAMER_TUNNEL_READY when the PTCP session is up
"""

from __future__ import annotations

import argparse
import os
import socket
import sys

# Ensure we import sibling modules from this directory.
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import main as dh_main  # noqa: E402


def patch_bind_port(port: int) -> None:
    original_bind = socket.socket.bind

    def bind(self, address):  # type: ignore[no-untyped-def]
        host, original_port = address
        if self.type == socket.SOCK_STREAM and original_port == 554:
            address = (host, port)
            print(f"CAMERA_STREAMER_BIND {host}:{port}", flush=True)
        return original_bind(self, address)

    socket.socket.bind = bind  # type: ignore[method-assign]


def patch_ready_banner(port: int) -> None:
    original_print = print

    def ready_print(*args, **kwargs):  # type: ignore[no-untyped-def]
        text = " ".join(str(a) for a in args)
        original_print(*args, **kwargs)
        if "Ready to connect" in text:
            original_print(
                f"CAMERA_STREAMER_TUNNEL_READY rtsp://127.0.0.1:{port}/cam/realmonitor?channel=1&subtype=0",
                flush=True,
            )

    # Patch builtins.print used by main.py readiness message.
    import builtins

    builtins.print = ready_print  # type: ignore[assignment]


def main() -> None:
    parser = argparse.ArgumentParser(description="dh-p2p tunnel for CameraStreamer")
    parser.add_argument("serial")
    parser.add_argument("-u", "--username", required=True)
    parser.add_argument("-p", "--password", required=True)
    parser.add_argument("-t", "--type", type=int, default=1)
    parser.add_argument(
        "-c",
        "--cloud",
        default="instaon",
        choices=["instaon", "instaon_ctc", "easy4ip", "amcrest"],
    )
    parser.add_argument("--local-port", type=int, default=1554)
    parser.add_argument("-d", "--debug", action="store_true")
    args = parser.parse_args()

    patch_bind_port(args.local_port)
    patch_ready_banner(args.local_port)

    print(
        f"CAMERA_STREAMER_START serial={args.serial} cloud={args.cloud} local_port={args.local_port}",
        flush=True,
    )
    dh_main.main(
        serial=args.serial,
        dtype=args.type,
        username=args.username,
        password=args.password,
        debug=args.debug,
        cloud=args.cloud,
    )


if __name__ == "__main__":
    main()
