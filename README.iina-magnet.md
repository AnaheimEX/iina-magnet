# iina-magnet — User Guide

> Private fork of [iina](https://github.com/iina/iina) (GPL-3.0) that adds a
> built-in **media library** for anime / movies, a **PikPak** cloud-drive
> integration (browse + direct cloud play), and a **Mikan (蜜柑计划)** browser
> that saves torrents straight into PikPak — closing the loop:
> *discover on Mikan → store in PikPak → play from the cloud, or scan & organize
> your local files.*
>
> For the development plan and architecture, see the
> [`planning`](https://github.com/AnaheimEX/iina-magnet/tree/planning) branch.

---

## Build / Run

```bash
git clone https://github.com/AnaheimEX/iina-magnet.git
cd iina-magnet

# 1. Prebuilt universal dylibs for iina itself (mpv, ffmpeg, …). The
#    PROJECT_NAME override lets the fork's directory name work.
PROJECT_NAME=iina-magnet ./other/download_libs.sh --skip-plugins

# 2. Build the app. The signing flags are REQUIRED — see the note below.
xcodebuild -scheme iina -configuration Debug -derivedDataPath /tmp/iina-dd \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build

open /tmp/iina-dd/Build/Products/Debug/IINA.app
```

> ⚠️ **Use `CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO`**, not
> `CODE_SIGNING_ALLOWED=NO`. After `other/change_lib_dependencies.rb` rewrites
> the dylibs' install names, an unsigned bundle is SIGKILLed by the macOS 26
> kernel (CODESIGNING / Invalid Page) on launch. The flags above make Xcode
> ad-hoc sign everything.

Requirements:

| | |
|---|---|
| Xcode | 26.x / Swift 6.x |
| macOS | 14.0 (Sonoma) or later |

> The `IinaMagnet` Swift package builds and tests standalone:
> `cd iina-magnet && swift test`. It depends on one C++ bridge,
> `AnitomyBridge` (filename parsing); no external build step is needed.

---

## First launch

You'll be asked to accept the **Disclaimer** (zh-Hans / en). "I Agree" enables
after you scroll to the bottom. Review it any time from the disclaimer entry.

The media library opens from the **「媒体库」button on IINA's launch window**
(below the build badge). The window auto-sizes to your display and scales its
contents up so everything stays comfortably clickable.

---

## Features

### Media library (local files)
- Add your anime / movie folders; IINA scans them and scrapes covers,
  synopsis, ratings and episode data from **Bangumi**.
- Browser with poster wall / list, a filter sidebar (watch state, media type,
  tags: genre / country / rating / quality / release group / year), search and
  sort, a resizable + collapsible sidebar.
- Per-title archive page: confirm / re-match / manual edit / mark-unmatched,
  play a version in iina, reveal in Finder, toggle watched.
- Watch progress is recorded automatically and completes an episode at ≥90%.

### PikPak cloud drive
- Sidebar entry **「PikPak 网盘」**. Login launches PikPak's official web page
  (it handles captcha / 2FA); the app captures the resulting tokens — your
  credentials never pass through the app's own code.
- Browse folders, sort (name / time / size), and **play videos directly from
  the cloud** in iina. Remote playback is tuned (larger network cache + a
  User-Agent); route the playback host through a proxy for overseas CDNs.

### Mikan (蜜柑计划)
- Sidebar entry **「蜜柑计划」** opens mikanani.me.
- Clicking a magnet / `.torrent` link offers **save to PikPak** (offline
  download) or **save & cloud-play**. Saves land in PikPak's
  `Pack From Shared` folder with their real titles.

---

## Architecture (1-minute tour)

- Almost everything lives in the isolated Swift package
  [`iina-magnet/`](iina-magnet) (`IinaMagnet` library + tests). Upstream IINA
  never touches it.
- The iina side has only a few small, comment-marked hooks
  (`// MARK: iina-magnet hook`): `iina/IinaMagnetBridge.swift` (new),
  `iina/AppDelegate.swift`, `iina/InitialWindowController.swift`.
- This keeps the fork easy to maintain — see **Following upstream** below.

---

## Roadmap / TODO

Shipped and verified: media library (scan / match / archive / watch progress /
tags / filters), PikPak (web login, browse, sort, cloud play, offline
download, **offline-task center**), Mikan → PikPak save & cloud-play,
screen-adaptive window scaling, upstream-sync tooling.

Not yet done — for future development:

- [ ] **More metadata sources** — only Bangumi is wired. Add **TMDB** (movies /
      non-anime, *Issue 06*) and **Douban** (*Issue 08*).
- [ ] **Multi-source metadata merge** (*Issue 10*) — combine Bangumi + TMDB +
      Douban into one record instead of a single source.
- [x] **PikPak offline-task center** — the PikPak screen has a 「离线任务」toggle
      listing running / pending / failed offline tasks with live progress, retry
      (re-submits the source URL) and delete (PikPak `drive/v1/tasks` APIs).
- [ ] **PikPak cloud files as a first-class library source** — scrape metadata
      for cloud items so they appear in the unified library, not just the file
      browser.
- [x] **PikPak captcha auto-refresh** — when the captured captcha token expires
      and a self-signed re-mint is rejected (rotated salts), the app now
      silently re-captures a fresh token from the web client in an offscreen
      web view (`PikPakCaptchaRecapturer`) before falling back to a re-login
      prompt.
- [x] **Mikan save names** — a JS click listener reads the episode title from
      the page DOM (and catches Mikan's `data-clipboard-text` magnet buttons,
      which aren't real links), so saved tasks carry the real title.
- [ ] **Crisper scaling (optional)** — the window uses a uniform `scaleEffect`,
      which slightly softens text at higher factors; true size scaling would be
      sharper but touches many hard-coded sizes.
- [x] **Trim dormant target** — the unused `LibtorrentBridge` target, its
      Obj-C++ bridge, and the vendored `lib/libtorrent` have been removed (the
      project no longer does BT itself; PikPak handles offline downloads).

---

## Following upstream IINA

This is a fork. To merge a new upstream release while keeping all custom
features:

```bash
./scripts/sync-upstream.sh v1.4.3        # use the target upstream tag
```

Full workflow, the fork-modification manifest, and conflict-resolution tips:
[`docs/UPSTREAM_SYNC.md`](docs/UPSTREAM_SYNC.md).

---

## Legal

This fork only adds technical capabilities (a media library, and integrations
with services you log into with **your own account**, the way tools like rclone
do). It ships **no** trackers, indexes, or sample content. You are solely
responsible for the legality of what you store, download, and play in your own
jurisdiction.

---

## License

GPL-3.0 (inherited from upstream iina). Source: [`AnaheimEX/iina-magnet`](https://github.com/AnaheimEX/iina-magnet).
