---
type: acceptance-report
date: 2026-11-11T02:18:12Z
swiftdossier_commit: e96a68b
binary: /Users/stovak/Projects/package-collection/pkg/SwiftDossier/bin/dossier
---

# Acceptance: dossier preview on mr-mr-charles (item 16)

Command per character, run from `~/Projects/podcasts/mr-mr-charles`:

`bin/dossier preview "characters/$NAME.dossier" --cast CAST.md --json`

Both passes were run back to back. The first pass should miss the cache and write the page. The second pass should hit it.

| Character | First run exit | First run hit | First run member | Second run exit | Second run hit | Key (sha256, full) |
|---|---|---|---|---|---|---|
| BILLY | 0 | false | true | 0 | true | 5499fc3cd5d81c8731282ea66a8753d4d9bb0a68ad011a5c1f419a974fced203 |
| DONNIE | 0 | false | true | 0 | true | 8342659542e74c1cca04f7679be5a0ee55eb2aabfa541d1a6776d5b104fdfe71 |
| MIMI | 0 | false | true | 0 | true | 441038e8679f850d10194436696f36f537f8e6d70e8c976d89c824764c5024f2 |
| MITCH | 0 | false | true | 0 | true | 00cbf42bbfd645a3b2c65e410d6bf8f6fb6729957f13ac8dd9c6f6a0cd8f2bf7 |

The second-run key matched the first-run key for every character.

## mr-mr-charles git status

`git status --porcelain` was recorded before and after the runs. The two snapshots are identical:

```
?? PROJECT.md.bak
```

The `PROJECT.md.bak` entry was already present before the runs and was not created by them.

## Visual check

The visual check in a `DossierView` test host is left to the human.
