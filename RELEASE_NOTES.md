## Release Notes
Release date: 2026-04-22

Summary:
- Added files: 0
- Updated files: 1
- Unchanged files: 11
- Target-only files: 0

### Updated
- update_title_editor_versions.sh (+13/-13)

### Highlights
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
- build_title_editor_batch_from_github.sh
- build_title_editor_batch_from_jamf_patch_catalog.sh
- title_editor_menu.sh
- title_editor_api_ctrl.sh
- title_editor_software_title_defaults_from_user_prompt.sh
- autopkg/TitleEditorAutoPkgHandoff.py
- autopkg/TitleEditorAutoPkgHandoff.recipe
- installomator/installomator_handoff.sh
