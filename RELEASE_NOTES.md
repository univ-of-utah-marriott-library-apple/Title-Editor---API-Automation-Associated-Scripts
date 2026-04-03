## Release Notes
Release date: 2026-04-03

Summary:
- Added files: 3
- Updated files: 5
- Unchanged files: 0
- Target-only files: 0

### Added
- build_title_editor_batch_from_jamf_patch_catalog.sh
- title_editor_software_title_defaults_from_user_prompt.sh
- update_title_editor_versions.sh

### Updated
- build_title_editor_batch_from_release_notes.sh (+165/-61)
- setup_title_editor_credentials.sh (+5/-5)
- build_title_editor_batch_from_github.sh (+57/-43)
- title_editor_menu.sh (+12/-4)
- title_editor_api_ctrl.sh (+6/-6)

### Highlights
- build_title_editor_batch_from_jamf_patch_catalog.sh:
  - [NEW] New synced script added to destination repository.
  - [FIX] Improved Jamf Patch OAuth credential handling and token retrieval flow.
  - [FIX] Improved keychain/env credential fallback behavior for non-interactive runs.
  - [FIX] Refined patch-title lookup path to reduce lookup mismatches.
  - [FIX] Improved normalization of extracted versions before batch output.
  - [FIX] Kept output formatting consistent for downstream Title Editor batch imports.
- title_editor_software_title_defaults_from_user_prompt.sh:
  - [NEW] New synced script added to destination repository.
  - [FIX] Refined prompt default logic for software-title mapping.
  - [FIX] Improved consistency for user-entered names resolving to expected titles.
  - [FIX] Reduced mismatch risk when title aliases are used in prompts.
  - [FIX] Improved behavior for non-interactive/default-driven executions.
- update_title_editor_versions.sh:
  - [NEW] New synced script added to destination repository.
  - [FIX] Strengthened end-to-end update orchestration across source->batch->import flow.
  - [FIX] Improved source fetch validation before writing batch output.
  - [FIX] Refined sequencing for generation/import/state update steps.
  - [FIX] Improved mismatch visibility in logs when data sources disagree.
  - [FIX] Improved consistency of latest-version extraction from generated batch files.
- build_title_editor_batch_from_release_notes.sh:
  - [NEW] Existing synced script updated from source changes.
  - [FIX] Improved release-notes and Mac App Store extraction logic to better detect valid versions.
  - [FIX] Normalized version ordering so newest versions are prioritized in batch output.
  - [FIX] Reduced stale-version selection risk when source pages mix old/new version blocks.
  - [FIX] Hardened fallback parsing for pages with irregular HTML structures.
  - [FIX] Improved consistency of short-format batch file generation.
- setup_title_editor_credentials.sh:
  - [NEW] Existing synced script updated from source changes.
  - [FIX] Enhanced setup/verify/migrate credential workflows for safer operations.
  - [FIX] Improved keychain diagnostics to avoid exposing plaintext sensitive values.
  - [FIX] Clarified verification error messaging and next-step recovery guidance.
  - [FIX] Improved migration checks for partial credential states.
  - [FIX] Reduced user-specific path leakage in help output.
- build_title_editor_batch_from_github.sh:
  - [NEW] Existing synced script updated from source changes.
  - [FIX] Refined GitHub release/tag discovery and parsing for mixed naming conventions.
  - [FIX] Improved latest-version detection across repos that publish both tags and releases.
  - [FIX] Reduced false positives from prerelease/label noise in release metadata.
  - [FIX] Improved resilience when repo APIs return sparse or irregular fields.
  - [FIX] Kept generated batch rows aligned with expected Title Editor import format.
- title_editor_menu.sh:
  - [NEW] Existing synced script updated from source changes.
  - [FIX] Improved menu integration with API/auth helper routines.
  - [FIX] Refined reconnect behavior after token expiry during menu operations.
  - [FIX] Improved keychain-assisted login fallback paths.
  - [FIX] Reduced reliance on user-specific absolute paths in instructions.
  - [FIX] Improved predictability for mixed interactive and CLI automation use.
- title_editor_api_ctrl.sh:
  - [NEW] Existing synced script updated from source changes.
  - [FIX] Hardened API connection and auth token lifecycle handling.
  - [FIX] Improved refresh/keepalive/expiry behavior for long-running sessions.
  - [FIX] Reduced edge-case failures when reconnecting after token expiration.
  - [FIX] Updated examples to use placeholder-safe credential values.
  - [FIX] Improved reliability for non-interactive scripted API workflows.
