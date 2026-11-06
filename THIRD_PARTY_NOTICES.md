# Third-party notices

Tuna TV is licensed under the GNU General Public License v3.0 (see `LICENSE`).
It links or depends on the following components, each under its own license.

| Component | Use | License |
|---|---|---|
| [AetherEngine](https://github.com/superuser404notfound/AetherEngine) 7.58.0 | Playback engine (FFmpeg demux, VideoToolbox decode, AVFoundation output) | LGPL-3.0 with an additional permission (see its LICENSE) |
| [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) 3.13.x (FFmpeg 8.1.x) | Dynamic `AetherLib*` frameworks embedded in the app | LGPL-2.1-or-later. Source: the FFmpegBuild tag referenced by AetherEngine's `Package.resolved` |
| dav1d | AV1 decoding (inside FFmpegBuild) | BSD-2-Clause |
| zimg | Scaling (inside FFmpegBuild) | WTFPL |
| libzvbi | Teletext (inside FFmpegBuild) | LGPL-2.0-or-later |
| [LibDovi](https://github.com/superuser404notfound/LibDovi) / dovi_tool | Dolby Vision RPU handling | MIT (© quietvoid and contributors) |

The FFmpeg-based frameworks stay dynamic libraries inside `Tuna TV.app/Contents/Frameworks`, so you can replace them. The complete source of Tuna TV is in this repository.

## Data sources

- **TMDB**: this product uses the TMDB API but is not endorsed or certified by TMDB. Users provide their own API key.
- **TVMaze**: show data under CC BY-SA 4.0, https://www.tvmaze.com/api
- **OMDb**: optional, user-provided key.
- **iptv-org**: channel metadata from https://github.com/iptv-org/database (public domain / CC0 data).

## Inspiration (no code copied unless noted)

- [IPTVMac](https://github.com/Goelir/IPTVMac) (GPL-3.0): the reference for Xtream URL handling and M3U parsing approaches.
- [IPTVnator](https://github.com/4gray/iptvnator) (MIT), [Hypnotix](https://github.com/linuxmint/hypnotix) (GPL): protocol edge cases and naming conventions.
- [Lume](https://github.com/bilipp/Lume) (AGPL-3.0): product ideas only. No code was copied.
