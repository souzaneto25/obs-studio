# Dynamic Stream Delay

**Unofficial feature — not part of OBS Studio upstream.**

## Purpose

Dynamic Stream Delay allows a streamer to apply a configurable broadcast delay
during an ongoing stream **without restarting the stream**. This prevents
stream-sniping in competitive games: the streamer activates the delay just
before entering a match, shows an optional waiting-media screen to viewers
while the delay accumulates, and disables the delay once the game is over,
snapping the audience back to the live feed.

---

## How it works

The delay operates on already-encoded packets — no raw frames are stored.
Packets received from the video/audio encoders are pushed into a ring-buffer;
once the buffer reaches the configured duration, the output pops and
transmits the oldest packets while continuing to accumulate new ones.

### State machine

| State | Description |
|---|---|
| `LIVE` (0) | No delay. Packets go directly to the output. |
| `ACCUMULATING` (1) | Buffering encoded packets. Optional waiting media is streamed to viewers. Starts on the next video keyframe after activation. |
| `DELAYED` (2) | Buffer full. Popping old packets while pushing live ones. |
| `CATCHUP` (3) | Delay disabled. Buffer cleared; output snaps back to live. |

### Activation flow

```
LIVE
  → Wait for the next video keyframe
  → Start buffering packets
  → Stream waiting-media to the audience (if configured)
  → When buffered duration ≥ target → DELAYED
```

### Deactivation flow

```
DELAYED (or ACCUMULATING)
  → Enter CATCHUP
  → Discard all buffered packets
  → Output returns to the current live feed
  → LIVE
```

> **Important**: when returning to live, the buffered content is **discarded**,
> not played back. Viewers see the current live feed immediately.

---

## How to activate

1. Open the **Dynamic Delay** dock from the *Docks* menu.
2. Set the desired delay time (10 – 600 seconds).
3. Optionally select a waiting-media file (video/image to loop while
   accumulating).
4. Start your stream normally.
5. Click **Enable Delay** (or use the hotkey) before entering the match.
6. The dock shows the current buffered duration and memory usage.

## How to return to live

Click **Disable Delay** (or use the hotkey) after leaving the match.

- The remaining buffered content is discarded immediately.
- The stream is **not** reconnected — no viewer drop.

---

## Memory usage

Buffer memory is determined by the encoded bitrate and configured duration:

```
estimated_memory ≈ video_bitrate_kbps × audio_bitrate_kbps × delay_seconds / 8
```

Default hard limit: **500 MB**.

The dock shows current memory usage and the configured limit. Activation is
blocked when the estimate exceeds the limit.

### Typical example

| Bitrate | Delay | Estimated memory |
|---|---|---|
| 6 Mbps video + 160 kbps audio | 120 s | ~95 MB |
| 6 Mbps video + 160 kbps audio | 600 s | ~473 MB |

---

## Limitations

- **Waiting-media requires an `ffmpeg_source`-compatible file.** Unsupported
  formats will cause a silent fallback (live feed is still buffered but no
  waiting-media is streamed).
- **No slow-motion or time-stretch.** When returning to live, buffered content
  is discarded, not accelerated.
- **Only the first video/audio encoder pair is used for waiting media.** If
  the output uses more tracks, only track 0 is replicated for waiting media.
- **Replay/slow-motion mode is not implemented** in this build.
- **Multitrack Video / Enhanced Broadcasting outputs** are not tested and
  may not be compatible — the feature will be silently unavailable on those
  outputs.
- **Recording and Replay Buffer outputs are unaffected.** Dynamic Delay only
  intercepts the streaming output's encoded-packet path.

---

## Compatible outputs

Tested:
- Standard RTMP streaming output (OBS built-in)

Not tested:
- RTMPS
- FFmpeg custom output
- SRT / RIST outputs
- Outputs with hardware-accelerated encoders on NVIDIA/AMD/Intel (should work
  as the buffer operates on encoded packets regardless of encoder)

---

## Hotkeys

Register hotkeys via *Settings → Hotkeys*:

| Action | Default |
|---|---|
| Enable Dynamic Delay | (none) |
| Disable Dynamic Delay / Return to Live | (none) |

> Hotkeys respect the current state and ignore invalid transitions (e.g.
> pressing Enable twice is idempotent).

---

## Configuration persistence

Saved per-profile:

- Target delay duration
- Waiting-media file path

Not saved:

- Buffer contents (always cleared on stream stop or OBS exit)

---

## Known issues and risks

- The buffer grows until the target duration is reached. If the stream drops
  mid-accumulation and reconnects, the buffer is cleared automatically.
- Timestamp continuity depends on the output's interleave thread running at a
  stable rate. Under severe CPU load, timestamps may drift slightly.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Dock not visible | Hidden dock | Docks menu → Dynamic Delay |
| Waiting media not shown | Unsupported file format or missing ffmpeg_source plugin | Use MP4/MKV H.264 file |
| Memory limit exceeded | Bitrate × delay too large | Lower delay or raise memory limit |
| Delay does not activate | Stream not active | Start stream first |
| Audio/video desync after transition | Encoders produced non-monotonic timestamps | Stop and restart stream |

---

## Build procedure (Linux / Ubuntu 24.04)

```bash
# Prerequisites
sudo apt-get install -y cmake ninja-build build-essential pkg-config \
  libavcodec-dev libavformat-dev libavutil-dev libswresample-dev libswscale-dev \
  libcurl4-openssl-dev libmbedtls-dev libgl1-mesa-dev libwayland-dev \
  libx11-dev libxcb-shm0-dev libxcb-xfixes0-dev libx11-xcb-dev libxcb1-dev \
  libpipewire-0.3-dev libpulse-dev libudev-dev libsrt-openssl-dev librist-dev \
  qt6-base-dev qt6-svg-dev qt6-wayland-dev libqt6svg6-dev \
  extra-cmake-modules libsimde-dev uthash-dev libjansson-dev \
  libdrm-dev libxcb-xinput-dev libxcb-xinerama0-dev libva-dev \
  libspeexdsp-dev libx264-dev libffmpeg-nvenc-dev nlohmann-json3-dev \
  libasound2-dev libv4l-dev

# Clone and configure
git clone git@github.com:souzaneto25/obs-studio.git
cd obs-studio
git checkout feat/dynamic-stream-delay
git submodule update --init --recursive
git tag 32.2.0-dynamic-delay  # required for version detection

cmake --preset ubuntu \
  -DENABLE_BROWSER=OFF \
  -DENABLE_VLC=OFF \
  -DENABLE_WEBSOCKET=OFF \
  -DENABLE_SCRIPTING=OFF

cmake --build build_ubuntu --parallel $(nproc)
```

## Executable location

After a successful build:

```
build_ubuntu/frontend/obs
```

Run from the repo root:

```bash
./build_ubuntu/frontend/obs
```

> OBS will look for plugins relative to the binary location. Running from
> the repo root is recommended for development builds.

---

*This is an unofficial build. For the official OBS Studio, see
https://github.com/obsproject/obs-studio.*
