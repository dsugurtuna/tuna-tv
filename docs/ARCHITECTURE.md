# Tuna TV architecture

Tuna TV is two layers:

- **TunaCore** (`Packages/TunaCore`): Foundation-only Swift. Networking rules, provider protocols, curation, metadata, library, search, ranking and guide. Unit-tested on Linux and macOS. No UI.
- **The app** (`App/`): SwiftUI on macOS 15+. It reads one `@Observable AppModel` and plays video through one AetherEngine instance.

```
Provider (Xtream / M3U)                      TMDB · TVMaze · OMDb · iptv-org
        │  (RequestGovernor: 1 in flight, paced, breaker)        │ (HostLimiter)
        ▼                                                        ▼
ProviderSession ──► cache (raw JSON) ──► Curator ──► Library ◄── MetadataService
        │                                  │            │
        │ xmltv (1×/day)                   │            ├─► SearchIndex
        ▼                                  ▼            ├─► RailComposer (Home/Movies/Series)
      Guide ───────────────────────────────────────────►└─► Insights
                                                         ▼
                                                    AppModel (@Observable)
                                                         ▼
                                       SwiftUI screens · PlayerModel ─► StreamGate ─► AetherEngine
```

## Provider Safety Spec

The previous version of the app got an account banned by firing six catalog calls in parallel, requesting the EPG for every visible channel, retrying failed streams automatically and opening a second connection for seek previews. Tuna TV 2 enforces:

| Area | Rule | Where |
|---|---|---|
| API concurrency | Exactly 1 request in flight per provider | `RequestGovernor` |
| Pacing | ≥ `minInterval` (Gentle 3 s / Balanced 1.5 s / Brisk 1 s) + jitter between request starts | `GovernorPolicy` |
| Coalescing | Identical queued or in-flight GETs share one response | `RequestGovernor` |
| Breaker | 401/403 → auth-blocked until the user acts. 429/458/509/520–527 or 2 consecutive 5xx/network errors → pause 5 min → 30 min → 2 h (or Retry-After). The state persists across relaunches. | `RequestGovernor` |
| Retries | Never automatic | everywhere |
| Budget | Soft daily cap (400). Background calls stop past it; user actions still pass. | `RequestGovernor` |
| Sync | Sequential: account → 3 category lists → live → vod → series. At most once per sync interval (24 h default). Cache-first on launch. An empty or failed section never wipes the cache. | `ProviderSession` |
| Details | `get_vod_info` / `get_series_info` only when a detail page opens. Cached for 14 / 3 days. | `ProviderSession` |
| Guide | `xmltv.php` once per 24 h, one request. `get_short_epg` only for the playing channel, cached 10 min. | `ProviderSession` |
| Images | Panel-hosted images: 1 at a time, ≥ 1 s apart, cached forever. TMDB/iptv-org artwork preferred. | `HostLimiter.Rule.providerImages`, `ImagePipeline` |
| Streams | One ticket per provider (`min(user cap, max_connections)`). 1.5 s grace after close and between opens. ≤ 8 opens per minute. | `StreamGate` |
| Zapping | Debounced (0.6 s default). Only the final channel opens. | `PlayerModel` |
| Engine | One AetherEngine. `maxConcurrentSourceRequests = 1`. No probes, prewarm, frame extractors, I-frame playlists or background scrub previews on provider URLs. 12 s stall watchdog. Bounded live recovery (1 in-place retry, then 1 reload ≥ 20 s later, then stop). | `TunaPlaybackEngine` |
| Identity | Same User-Agent for API, images and streams (VLC-compatible default) | `ProviderConfig.userAgent` |

## Curation

`NameParser` tokenizes provider names: prefix/suffix tags, superscripts, quality, source, HDR, codec, audio markers, platforms, adult/backup/timeshift markers, years, and episode patterns in many languages. `TitleKey` builds the dedupe key. `Curator` then:

- merges duplicates into `Title`s (movies by key + year, series by key) and `Channel`s (key + country, with timeshift feeds kept apart),
- scores variants (quality, HDR, world match, codec, backup, low-grade source, playback failures, verified quality),
- places each item in the **showcase** (world match + quality ≥ the showcase floor, no cam copies) or a **Vault shelf** (Blu-ray & Disc, Full HD & HD, Legacy, Cam & Screeners, Other Languages, Unsorted, Adult),
- relaxes the quality floor per kind when the showcase would be nearly empty, and tells the user.

## Metadata and ranking

`MetadataService` enriches titles in priority order: the detail page the user opened, then visible rails, then a background trickle. It uses the provider's TMDB id when present, otherwise a TMDB search scored by `TitleMatcher`. Series fall back to TVMaze when no TMDB key is set. OMDb ratings are merged in when an IMDb id is known. `Ranker` combines a Bayesian weighted rating (m = 500, C = 6.8), popularity, recency and quality. `RailComposer` builds the rails: Top 10, Trending (TMDB trending ∩ catalog), New Arrivals, Ultra HD, Because You Watched, Critically Acclaimed, Hidden Gems, per-world, genres and collections.

## UI

A floating glass top bar over full-bleed content. Pages are a custom overlay stack (`Router`), so every transition is a hand-tuned spring. Highlights: Ken Burns hero with title logos and muted trailers, Top 10 numerals, hover-reveal cards, the Vault's box-opening animation, the curation theater during the first sync, a timeline guide, a zapping strip, a ⌘K palette, an Insights dashboard and the Provider Shield.

## Testing

- `swift test --package-path Packages/TunaCore` on Linux (Docker `swift:6.2-noble`) and macOS.
- CI (`.github/workflows/build.yml`): a fast app type-check without the engine (`TunaTVCheck` target), a Release build with AetherEngine, a `--self-test` launch, `--snapshots` rendering every screen from the demo library to PNG, and a DMG.
