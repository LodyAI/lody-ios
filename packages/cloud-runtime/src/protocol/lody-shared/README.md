# Vendored Lody shared modules

These files mirror `packages/shared/src` of the public Lody repository at the
commits recorded in `provenance.json` (AGPL-3.0-only, with the MIT license
recorded in the fractional index header). Each copy follows upstream formatting
and preserves its bytes except for the relative import extensions listed under
`adapt`. Prettier ignores this directory.

- `status-view/` — `buildStatusViewLayout`, `planStatusViewCommand`, tiers, the
  opened-by tree and snooze presets, with the golden vectors in `vectors/`.
- `pinned-sections.ts`, `vendor/loro-fractional-index.ts` — what they import.
- `session-sync-progress.ts` observes Loro bootstrap bytes and incremental stream offsets.

`apps/ios/tests/cloud/status-view.test.mjs` checks every file against its
recorded SHA-256 after undoing the adaptations, and runs both vector files
against these copies. To refresh: copy the same paths from the new upstream
commit, re-apply only the import extensions, and update `provenance.json`.
Never edit the logic here; change it upstream and re-vendor.
