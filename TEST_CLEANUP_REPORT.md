---
type: test-cleanup-report
state: current
---

# Test Cleanup Report: OPERATION HIDDEN SKETCHBOOK

## Removed

| file:test_name | reason | confidence |
|---|---|---|
| none | no mission-added test matched patterns 1-12 | n/a |

## Flagged for Review

| file:test_name | concern | recommended action |
|---|---|---|
| Tests/DossierUITests/ManifestWatcherTests.swift:liveSourceConstructs | Creates a live DispatchSource (`ManifestWatcher(bundleURL:)` activating) and cancels it at once. It never waits for an event, so it is not timing-dependent, but it does touch a real FS event source. | Keep; confirm on CI. Delete if it ever flakes. |
| Tests/DossierUITests/DossierViewModelTests.swift:storeNote | Makes the store directory read-only (chmod 0o555) to force a store failure. Fails if CI runs as root, since root ignores the mode. | Keep (macOS runners are non-root); confirm. |
| Tests/DossierTests/RebuildTests.swift:unchanged | Uses `Date(timeIntervalSinceNow: -86_400)` as test data and asserts the file's mtime is later. No wait, but it relies on the real clock. | Keep; consider an injected clock. |
| Tests/DossierUITests/ViewModelSupport.swift (`UIProject.made`) | Fixed timestamp used as data. Not a real-time dependency. | None. |
| Makefile `smoke` target | The preview check writes `mktemp` directories and does not remove them. Not a Swift test. | Add a cleanup trap. |

Tests that touch marker expiry (`markerGivesUpdating`, `markerShowsStoredPreview`) use `beginUpdate`/`endUpdate` and `refreshToken` directly. They do not wait on the real expiry sleep, so they are fine. No test file has a function over 200 lines.

## Build Verification

not needed (no deletions)

## What was checked per file

Every file was diffed against e35023c and grepped for: sleep, deadline, timeout, Duration, confirmation (time-limited), Task.yield, Date(), `/Users/`, `/home/`, home-directory APIs, env vars, URLSession and real hosts, random/UUID use, skip and disabled traits, DispatchSource use, and absolute paths.

- CLICoreTests/CommandTests, FileAcceptanceCommandTests, PreviewCommandTests, RenderCommandTests: temp directories and `.dossier-format` fixtures; the only env var is DOSSIER_SPEC_DIR, set by `make`. Clean.
- CoreTests/ChecksumTests, CompletenessTests, ManifestTests: one-line changes. Clean.
- DossierTests/PreviewKeyTests, PreviewStoreTests, PreviewTests, SchemaEvaluatorTests: temp directories; `example.invalid` URLs are never fetched. Clean.
- DossierTests/RebuildTests: flagged (clock data) above.
- DossierUITests/DossierViewModelTests: injected `ManualWatching` and `RecordingBuilder`; no real waits. One flag (`storeNote`).
- DossierUITests/ManifestWatcherTests: non-activating watcher and `handleEvent()`; one flag (`liveSourceConstructs`).
- DossierUITests/PreviewNavigationTests: pure policy checks; the `example.com` URLs are never fetched. Clean.
- DossierUITests/ViewModelSupport.swift: support file, temp directories only. Clean.
