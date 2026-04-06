## Release Notes
Release date: 2026-04-06

Summary:
- Added files: 1
- Updated files: 0
- Unchanged files: 8
- Target-only files: 0

### Added
- setup_jamf_pro_credentials.sh

### Highlights
- setup_jamf_pro_credentials.sh:
  - [NEW] New synced script added to destination repository.
  - [FIX] Improved Jamf Pro API credential setup and secure keychain storage workflow.
  - [FIX] Added credential verification flow to reduce failed API auth during automation runs.
  - [FIX] Improved operator prompts and guidance for safer setup in user context.
  - [FIX] Reduced manual environment-variable handling by standardizing secure credential loading.

### Unchanged
- build_title_editor_batch_from_release_notes.sh
- setup_title_editor_credentials.sh
- build_title_editor_batch_from_github.sh
- build_title_editor_batch_from_jamf_patch_catalog.sh
- title_editor_menu.sh
- title_editor_api_ctrl.sh
- title_editor_software_title_defaults_from_user_prompt.sh
- update_title_editor_versions.sh
