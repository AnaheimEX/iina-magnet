# iina-magnet — User Guide

> Private fork of [iina](https://github.com/iina/iina) (GPL-3.0) that adds RSS subscriptions, BitTorrent streaming, and a built-in media library (Phase 2).
>
> This document covers everyday usage. For the development plan and architecture, see the [`planning`](https://github.com/AnaheimEX/iina-magnet/tree/planning) branch of this repository.

---

## Install / Build

```bash
git clone https://github.com/AnaheimEX/iina-magnet.git
cd iina-magnet

# 1. Vendored dependencies for iina itself (mpv, ffmpeg)
./other/download_libs.sh

# 2. Vendored libtorrent universal static library (one-time, ~7 min)
./lib/libtorrent/build.sh

# 3. Build the app
xcodebuild -project iina.xcodeproj \
           -scheme iina \
           -configuration Debug \
           -derivedDataPath build
open build/Build/Products/Debug/IINA.app
```

Requirements:

| | |
|---|---|
| Xcode | 26.5 / Swift 6.x |
| macOS | 14.0 (Sonoma) or later |
| Homebrew | for `cmake` + `openssl@3` used by libtorrent build |

---

## First launch

You will be asked to accept the **Disclaimer** (zh-Hans / en double tab). The "I Agree" button is enabled only after you scroll to the bottom of the active language. You can review the disclaimer any time via `Magnet → Disclaimer…`.

---

## Quick start

### 1. Add a subscription source

`Magnet → RSS Manager…` → `+` button → enter URL + display name.

**Public source example** (no login):

```
https://nyaa.si/?page=rss
```

**Login-required source** (e.g. mikanani.me "MyBangumi"):

1. Sign in via Safari/Chrome
2. Open Developer Tools → Network tab → load the RSS page
3. Copy the **Cookie** header (`__cfduid=…; bangumi=…`)
4. In RSS Manager → source's `Authentication` panel → paste into `Cookie header`

### 2. Write a rule

`RSS Manager` → select source → `Rules` tab → `Add rule`.

| | |
|---|---|
| **Include** | comma-separated keywords; all must appear in the title |
| **Exclude** | comma-separated; any match rejects the item |
| **Regex** (optional) | one regex; if non-empty, **overrides** include/exclude |
| **caseSensitive** | off by default |

Common include/exclude tokens:

- Simplified Chinese: `简`, `CHS`, `SC`, `简日`
- Traditional Chinese: `繁`, `CHT`, `TC`
- Resolution: `1080p`, `4K`, `2160p`
- Release groups: `LoliHouse`, `喵萌奶茶屋`, `SweetSub`, `Nekomoe kissaten`
- Reject: `RAW`, `MP4` (if you want only `.mkv`)

Example: only download 1080p with simplified Chinese subs:

```
Include: 1080p, 简
Exclude: RAW
```

### 3. Wait for the next poll

`Settings → RSS → Poll interval` defaults to 30 min. To trigger immediately, open the source's detail and click `Poll now`.

### 4. Watch

`Magnet → BT Manager…` will show the task as soon as the rule fires. **Double-click** to start streaming — playback begins as soon as the head of the file is downloaded. Subtitles inside the torrent are auto-copied to the video's sidecar location and picked up by mpv.

---

## Settings (`Magnet → Settings…`)

### General

* **Cache directory** — where downloads land while in-flight
* **Completed directory** — where files move when they finish (default: `~/Movies/iina-magnet`)
* **Move to completed when finished** — toggle off to keep things in cache
* **Disk warning threshold** — alerts if free space falls below this

### BitTorrent

* **Listen port** — default 6881
* **DHT / PEX / LSD** — defaults on (peer discovery)
* **UPnP / NAT-PMP** — **off** by default; only enable on networks you control
* **Seeding strategy** — default is "Zero seed" (download finishes → upload stops). Change to ratio-based or "Seed forever" if you participate in a private tracker community

### RSS

* **Default poll interval** for newly added sources
* **Auto-start downloads on match** — toggle off if you want to manually confirm

---

## Troubleshooting

| Problem | Likely cause | Fix |
|---|---|---|
| RSS source shows orange dot ⚠ | Site rejected request (cookie expired, 403, etc.) | Update Cookie header in source settings |
| Magnet stays "Resolving" forever | Tracker / DHT not reachable | Verify network; toggle DHT on; verify firewall on listen port |
| Streaming stutters | Buffer ahead too thin for connection speed | Lower video bitrate estimate (Settings → not yet exposed; current default 2 MB/s ≈ 16 Mbps) |
| Built-in subtitles not loading | Subtitle file in a non-standard layout | Open download folder; ensure `.srt`/`.ass` exists next to video |
| Build fails with `openssl/opensslv.h not found` | Homebrew openssl@3 not installed | `brew install openssl@3` |
| `lib/libtorrent/build.sh` fails downloading boost | archives.boost.io throttled | Re-run; script resumes from cached state |

---

## Known limitations

* No iOS / iPadOS support
* No built-in tracker list (you provide URLs / magnets yourself)
* Default seeding is "Zero" — change in settings for community-trackers
* Media library (`Magnet → Library…`) is Phase 2 and currently disabled
* Streaming heuristics use a fixed 2 MB/s bitrate estimate; high-bitrate 4K may need manual bump (Phase 2 will adapt)

---

## Legal

This fork only adds technical capabilities (RSS subscription, BT transport, library). It does **not** ship trackers, indexes, or sample content. Users are solely responsible for the legality of what they download and upload in their own jurisdiction.

Default safety posture:

- **Zero seeding** (no automatic uploads after download completes)
- **UPnP disabled** (no automatic router exposure)
- **BT encryption forced** by default

See the full disclaimer at `Magnet → Disclaimer…`.

---

## License

GPL-3.0 (inherited from upstream iina). Source: [`AnaheimEX/iina-magnet`](https://github.com/AnaheimEX/iina-magnet).
