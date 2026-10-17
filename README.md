# IINA Cloud · PikPak + Mikan

Browse the full Mikan website, save releases to PikPak, and play cloud videos in
[official IINA](https://iina.io) through a plugin and its bundled native macOS companion.

**[简体中文](README.zh-CN.md)** · [Download](#installation) · [Build](#building) · [Architecture](#architecture)

This is an independent, unofficial plugin project. It does not ship or modify the
IINA application. This repository previously held a personal IINA fork; the
current tree and history contain only the cloud plugin and its native companion.
Anime4K and the former media library are not included.

> Version 1.1.0 is a local development build. The companion has been compiled and
> the plugin packaged; the complete login/save/play flow and performance have not
> been validated against a live account. The bundled app is ad-hoc signed, not
> Developer ID signed or notarized.

## Features

- **Full Mikan browsing.** Open the complete website in a separate, resizable
  native `WKWebView` window, with images, navigation and release pages intact.
- **Save and play.** Capture magnet links, confirm saving to PikPak, then open the
  playable cloud file in an IINA player managed by the plugin.
- **PikPak drive access.** Sign in through PikPak's website, browse folders and
  video files, and view offline tasks in the native companion.
- **Persistent sessions.** Store account tokens in the local macOS Keychain and
  website state in WebKit's persistent data store. Refresh tokens are renewed as
  needed; account changes and explicit sign-out remain isolated.
- **Playback preparation.** Prepare authentication and look up the destination
  folder while the magnet confirmation is open. Poll readiness more frequently
  initially, then back off while preserving timeout and cancellation handling.
- **Player acknowledgment.** Distinguish task creation, playable-file readiness
  and IINA's `iina.file-loaded` event instead of treating a launch request as
  successful playback.
- **Background buffering.** Request playback without an initial cache-fill pause,
  with up to 60 seconds of read-ahead and a 256 MiB forward-cache ceiling. Video
  data is fetched by the player, without a second browser prefetch.
- **System proxy integration.** Use macOS networking in the companion and pass an
  explicit system HTTPS proxy to mpv for cloud playback.

These settings aim to reduce avoidable waiting. They do not guarantee a startup
time or remove PikPak processing delays, account restrictions or network limits.

## Requirements

| Component | Requirement |
| --- | --- |
| Player | Official IINA 1.5 with plugins enabled |
| System | macOS 14 or later |
| Included binary | Apple Silicon / arm64 |
| Account | Your own PikPak account |
| Source build | Xcode command-line tools with Swift 6 or later |

The implementation uses public IINA plugin APIs. Future IINA releases depend on
continued API compatibility; they are not automatically considered supported.
Intel binaries are not included in this package.

## Installation

1. Download [pikpak-mikan-1.1.0.iinaplgz](https://github.com/AnaheimEX/iina-magnet/raw/refs/heads/develop/dist/pikpak-mikan-1.1.0.iinaplgz).
2. Open IINA **Settings → Plugins**, install the local plugin package and enable it.
3. Grant the declared **file-system** permission. The plugin uses it to launch its
   bundled companion and exchange playback requests through its private data directory.
4. Use the plugin menu to open **PikPak 网盘** or **蜜柑计划**.
5. Sign in through the PikPak window, then use Mikan's save or save-and-play action.

The native companion is inside the plugin package; it does not need to replace
IINA in `/Applications`. First use may require a fresh login or Keychain access
approval because the companion has its own application/signing identity.
macOS may restrict an unnotarized local build. For public distribution, use a
consistent Developer ID identity and notarize the companion; this repository does
not instruct users to disable system security protections.

To update, replace the installed plugin with a newer package through IINA. Remove
or disable it in the same settings page. Credentials and WebKit state are managed
by the companion; uninstalling the plugin is not a guaranteed account-data wipe.
Use the companion's sign-out action when ending an account session.

## Architecture

```text
Official IINA
  └─ JavaScript plugin (public plugin APIs)
       ├─ Menu entries and managed playback window
       ├─ Playback / cache / proxy options
       └─ Private file mailbox
            └─ IINA Cloud.app
                 ├─ AppKit + SwiftUI windows
                 ├─ WebKit: Mikan website and PikPak web login
                 ├─ PikPak authentication, drive and offline tasks
                 └─ Keychain + persistent WebKit data
```

The JavaScript layer starts the companion with macOS `open` and uses private files
for requests and acknowledgments. There is no local HTTP server and no dependency
on IINA application source, a patched player, or private player APIs.

The Swift module retains the internal name `IinaMagnet` for the cloud services;
it is companion code, not the IINA application. Existing focused tests are kept
under `native/Tests`. The package workflow is manual-only and has not been run for
this repository conversion.

### Save-to-play lifecycle

1. The native Mikan web window captures a magnet link and asks for confirmation.
2. Authentication and an existing destination folder are prepared in advance;
   this preparation does not create a cloud task.
3. Confirmation creates or resolves the PikPak offline task. The original task,
   folder and file-resolution logic is retained.
4. Readiness polling starts with short intervals, increasing to two seconds, with
   the existing 90-second readiness deadline and account/cancellation guards.
5. The resolved HTTPS media URL is handed to the plugin, which opens a managed
   IINA player with its buffering and proxy options.
6. The companion waits for IINA's file-loaded acknowledgment. Cancelling the local
   request does not delete a cloud task that PikPak has already accepted.

### Credentials and privacy

Keychain is encrypted storage **on this Mac**. Account access/refresh tokens use
Keychain; new items are device-only and do not synchronize through iCloud. WebKit
stores its own cookies and website storage separately in the normal browser data
store. A Keychain write failure is reported rather than writing new tokens to
plaintext preferences. Existing legacy fallback data is removed only after a
successful secure migration when it is accessible to the current app.

Account tokens and cookies are not passed to the JavaScript plugin. The mailbox
directory uses mode `0700`, and companion-written files use `0600`. Signed media
URLs are temporary playback data and are removed from the mailbox on completion;
IINA's own history and logging behavior still applies. Do not include signed URLs,
cookies, tokens or account details in public issue reports.

### Proxy routing

The browser/API layer follows macOS networking. Playback reads the explicit
system HTTPS proxy and supplies it as mpv's HTTP proxy. The bridge does not parse
PAC files or translate SOCKS-only settings.

For Surge, a user can create an `IINA Cloud` selection group using their own
Singapore and Hong Kong policies, then route PikPak and the Mikan domains to it:

```ini
DOMAIN-KEYWORD,pikpak,IINA Cloud
DOMAIN-SUFFIX,mikanani.me,IINA Cloud
DOMAIN-SUFFIX,mikanime.tv,IINA Cloud
```

Create the policy group before adding these rules. No subscription URLs, proxy
nodes or personal Surge configuration are bundled. Singapore versus Hong Kong is
a user choice, not a measured speed ranking; CDN hostnames may require additional
rules depending on the actual playback URL and local proxy setup.

## Repository layout

```text
plugin/          Official IINA plugin manifest and JavaScript entry points
native/          Swift package for the bundled native companion
  Companion/     App bundle metadata
  Sources/       Web windows, authentication, cloud services and playback bridge
  Tests/         Existing package tests
dist/           Installable plugin package
.github/         Manual native-package workflow
LICENSE          GPL-3.0 license
```

The generated `plugin/companion/` directory is ignored. The committed `.iinaplgz`
archive contains the native binary and resource bundle needed for installation.

## Building

Clone the plugin repository or download **Code → Download ZIP**:

```sh
git clone https://github.com/AnaheimEX/iina-magnet.git
cd iina-magnet
```

Build and assemble the companion on macOS, from the repository root:

```sh
swift build --package-path native -c release --product IINACloud
PRODUCTS="$(swift build --package-path native -c release --show-bin-path)"
APP="plugin/companion/IINA Cloud.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/IINACloud" "$APP/Contents/MacOS/IINACloud"
cp native/Companion/Info.plist "$APP/Contents/Info.plist"
ditto "$PRODUCTS/IinaMagnet_IinaMagnet.bundle" \
  "$APP/Contents/Resources/IinaMagnet_IinaMagnet.bundle"
codesign --force --sign - --timestamp=none "$APP"
```

This uses local ad-hoc signing. It does not notarize the companion or produce an
Intel/universal binary; SwiftPM builds for the host architecture by default.
Package the plugin after removing any older archive at the same output path:

```sh
mkdir -p dist
rm -f dist/pikpak-mikan-1.1.0.iinaplgz
(cd plugin && zip -qry ../dist/pikpak-mikan-1.1.0.iinaplgz \
  Info.json README.md LICENSE global.js main.js companion)
```

Keep the manifest, companion version and archive filename aligned when preparing
an update. Building or packaging alone does not validate real-account playback.

## Contributing

Keep changes focused on the cloud plugin and native companion. Include the IINA,
macOS and plugin versions, the action taken and a redacted error description when
reporting a problem. Do not upload account credentials or private media links.
Existing tests can be run deliberately with `swift test --package-path native`;
no automatic performance or real-account claims are implied by them.

## License and acknowledgments

[GPL-3.0](LICENSE). Existing copyright and license notices are retained. IINA is a
separate project maintained by [iina/iina](https://github.com/iina/iina). PikPak and
Mikan are third-party services; this plugin is not affiliated with or endorsed by
their operators or the IINA project. Use your own account and authorized content.
