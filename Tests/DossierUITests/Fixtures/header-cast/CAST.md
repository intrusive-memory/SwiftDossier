---
type: cast
schemaVersion: 1
cast:
- character: 'BYSTANDER #2'
  role: guest
  voices: {}
  manifest: 'characters/BYSTANDER #2.dossier/manifest.json'
- character: LANTERN
  voices: {}
  manifest: characters/LANTERN.dossier/manifest.json
- character: WREN HALLOWAY
  voices: {}
  manifest: characters/WREN HALLOWAY.dossier/manifest.json
- character: THE FERRYMAN
  displayName: The Ferryman
  role: background
  voices: {}
  manifest: characters/THE FERRYMAN.dossier/manifest.json
---
# Cast

Synthetic data only, for the dossier header's tests. The bundles are dossier-format's
`examples/valid/` cases, copied in by the tests:

- `BYSTANDER #2` is `empty-background`. Its manifest says `background`; here it's `guest`.
- `LANTERN` has no role, and its bundle doesn't exist, so it can't be opened.
- `WREN HALLOWAY` is `complete-lead`. Its name has a space, and only its manifest has a role.
- `THE FERRYMAN` is `hand-edited-member`, with a `displayName`.
