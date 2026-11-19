---
type: test-cleanup-report
state: current
---

# TEST_CLEANUP_REPORT.md: OPERATION LOOSE LEAF

The scan covered the 8 test files this mission added or changed since `c3fa762`. It looked for hardcoded user paths, network calls, sleeps, `Date()` assertions, unseeded randomness, async delays and disabled tests.

## Removed

None.

## Flagged for Review

| file:test | concern | recommended action |
|-----------|---------|--------------------|
| `Tests/DossierTests/RealProjectRoundTripTests.swift` | It reads a local project (`DOSSIER_ACCEPTANCE_PROJECT`) | Keep it. It is disabled unless `make acceptance` sets the variable, so it never runs in CI (SD-4) |

The only pattern hit was `LocationsTests.outOfDate`, a test from before this mission whose name contains "Date(". It is a false positive.

## Build Verification

`make test` (macOS) and `make test-ios` both passed in Sortie 7 (`ll-s7-test.log`, `ll-s7-ios.log`).
