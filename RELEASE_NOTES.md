## Release Notes
Release date: 2026-04-10

Summary:
- Added files: 0
- Updated files: 3
- Unchanged files: 6
- Target-only files: 0

### Updated
- build_title_editor_batch_from_github.sh (+48/-18)
- title_editor_menu.sh (+199/-3)
- update_title_editor_versions.sh (+1/-1)

### Highlights
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
- update_title_editor_versions.sh:
  - [NEW] Existing synced script updated from source changes.
  - [FIX] Strengthened end-to-end update orchestration across source->batch->import flow.
  - [FIX] Improved source fetch validation before writing batch output.
  - [FIX] Refined sequencing for generation/import/state update steps.
  - [FIX] Improved mismatch visibility in logs when data sources disagree.
  - [FIX] Improved consistency of latest-version extraction from generated batch files.

### Unchanged
- build_title_editor_batch_from_release_notes.sh
- setup_jamf_pro_credentials.sh
- setup_title_editor_credentials.sh
- build_title_editor_batch_from_jamf_patch_catalog.sh
- title_editor_api_ctrl.sh
- title_editor_software_title_defaults_from_user_prompt.sh
