## Release Notes
Release date: 2026-04-15

Summary:
- Added files: 2
- Updated files: 1
- Unchanged files: 8
- Target-only files: 0

### Added
- autopkg/processors/TitleEditorAutoPkgHandoff.py
- autopkg/recipes/TitleEditorAutoPkgHandoff.recipe

### Updated
- update_title_editor_versions.sh (+21/-0)

### Highlights
- autopkg/processors/TitleEditorAutoPkgHandoff.py:
  - [NEW] New synced script added to destination repository.
  - [FIX] Added reusable AutoPkg processor to run upstream recipe + Title Editor handoff flow.
  - [FIX] Supports signal-only mode and apply-current mode through one processor entry point.
  - [FIX] Improved portability by allowing explicit AutoPkg command/script path overrides.
- autopkg/recipes/TitleEditorAutoPkgHandoff.recipe:
  - [NEW] New synced script added to destination repository.
  - [FIX] Added generic AutoPkg recipe wrapper for upstream recipe + Title Editor handoff workflow.
  - [FIX] Exposes SOURCE_RECIPE, TITLE_EDITOR_ITEM, and HANDOFF_MODE inputs for flexible reuse.
  - [FIX] Keeps AutoPkg-driven detection and Title Editor update behavior in one repeatable run path.
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
