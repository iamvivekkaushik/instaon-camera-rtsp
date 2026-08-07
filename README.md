# CameraStreamer

macOS app for CP Plus / gCMOB cameras:

1. **InstaOn SOAP lookup**
2. **Dahua P2P tunnel** via bundled [dh-p2p](https://github.com/khoanguyen-3fc/dh-p2p) (patched for InstOn clouds)
3. **Local RTSP → ffmpeg HLS → AVPlayer**

## Run

```bash
cd CameraStreamer
./scripts/run.sh
```

Needs `Vendor/ffmpeg` and `Vendor/dh-p2p-bin`.

Rebuild tunnel binary:

```bash
source "$HOME/.cargo/env"
cd Vendor/dh-p2p
CARGO_TARGET_DIR=target cargo build --release
cp target/release/dh-p2p ../dh-p2p-bin
```

## Usage

1. Enter InstaOn ID / serial  
2. Enter **device** username / password  
3. Look Up (optional) → **Start Stream**

| Mode | Behavior |
|------|----------|
| Auto | P2P Relay → P2P (hole-punch→relay) → direct WAN RTSP (if not a pure-P2P device) |
| P2P | Tunnel via InstOn (`-t 0`); hole-punch with auto-fall back to agent relay |
| P2P Relay | Force `--relay` through cloud agent (most reliable for WAN) |
| Direct RTSP | WAN/LAN RTSP only |

Device user/password authenticate **RTSP digest** inside the tunnel. Channel auth uses `-t 0` (InstOn devices often hang on `-t 1` when salt is empty). Prefer **Sub** stream over P2P. Close gCMOB live view while testing.

## Clouds (dh-p2p `-c`)

| Cloud | Host |
|-------|------|
| `instaon` (default) | `instaonserver.com:8800` |
| `instaon_ctc` | `instaonserverctc.com:8800` |
| `easy4ip` | `www.easy4ipcloud.com:8800` |

Credentials come from the gCMOB app config.

## If P2P fails with 404 on `p2p-channel`

The cloud knows the SN but the device is not online on that P2P server. Open live view once in the phone app so the NVR registers, then retry here.

## Run dh-p2p

```
./Vendor/dh-p2p-bin --relay -c instaon -t 0 -p 0:1555:554 2009011801001104
```
