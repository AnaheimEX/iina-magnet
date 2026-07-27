# Third-Party Notices

## Community IINA Anime4K sidebar under GPL-3.0

- Project: `yorkyang2333/iina-anime4k`
- Plugin identifier: `com.yorkyang2333.anime4k`
- Pinned commit: `a416d4c669f4136006e5a9bbe3d27dcf64471bbd`
- License: GNU GPL version 3

The sidebar visual hierarchy and CSS styling were adapted from the pinned
community plugin and modified for IINA Magnet's managed controls. Runtime,
host integration, integrity verification, and installer behavior remain the
independent IINA Magnet implementation. The complete GPL-3.0 text covering
the adapted sidebar is in `LICENSE`.

## Anime4K shaders under MIT

- Project: Anime4K
- Upstream: `bloc97/Anime4K`
- Pinned commit: `7684e9586f8dcc738af08a1cdceb024cc184f426`
- Copyright: Copyright (c) 2019 bloc97
- License: MIT

Twelve files in the reviewed shader subset are copied from the pinned upstream
commit without source-code modification under MIT. The complete retained MIT
license text is in `licenses/Anime4K-LICENSE.txt`.

## AutoDownscalePre shaders under Unlicense

These two pinned files are not MIT-licensed:

- `shaders/Anime4K_AutoDownscalePre_x2.glsl`
- `shaders/Anime4K_AutoDownscalePre_x4.glsl`

Each file is copied byte-for-byte from upstream and retains the same complete
24-line public-domain dedication and warranty disclaimer in its header. The
applicable SPDX license identifier is `Unlicense`; upstream names no copyright
holder for these two files and provides no standalone Unlicense file. See
`licenses/AutoDownscale-Unlicense-NOTICE.txt` for the package-specific notice.

The ordered Fast and HQ preset chains are transcribed from the pinned upstream
`md/Template/GLSL_Mac_Linux_Low-end/input.conf` and
`md/Template/GLSL_Mac_Linux_High-end/input.conf` templates.
