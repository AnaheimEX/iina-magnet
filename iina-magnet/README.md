# iina-magnet — Swift package

This is the **new code** of the iina-magnet fork. iina's upstream code lives outside this directory in `iina/`, `iina-cli/`, `iina-plugin/`, etc. and stays as-is (modulo small marked hooks).

## Phase 0 status

- ✅ Empty `IinaMagnet` library (`Bootstrap`, `PersistenceController` stubs)
- ✅ Swift package builds & `swift test` runs the smoke test
- ⏸ **Not yet linked into the iina Xcode target** — that link is made when AppDelegate gets its hook in Issue 03

## Build & test (standalone)

```bash
cd iina-magnet
swift build
swift test
```

## Roadmap (this package)

| Phase | Adds |
| --- | --- |
| 1 | LibtorrentBridge, TorrentManager, StreamPlanner, RssService, RuleEngine, SubscriptionScheduler, CompletionPipeline, RSS/BT Manager SwiftUI windows, Disclaimer flow |
| 2 | MetadataProviders (TMDB/Bangumi/Anilist/豆瓣), MetadataMerger, Scanner, Library + Archive UI, Tag, WatchProgress |

See `../docs/iina-hooks.md` for the registry of changes to upstream iina files.
See the project's `planning` branch (`git checkout planning`) for the full development plan, PRDs, and ADRs.
