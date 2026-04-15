## Release Notes
Release date: 2026-04-15

Summary:
- Added files: 0
- Updated files: 1
- Unchanged files: 8
- Target-only files: 0

### Updated
- title_editor_menu.sh (+69/-13)

### Highlights
- title_editor_menu.sh:
  - [NEW] Existing synced script updated from source changes.
  - [FIX] Improved menu integration with API/auth helper routines.
  - [FIX] Refined reconnect behavior after token expiry during menu operations.
  - [FIX] Improved keychain-assisted login fallback paths.
  - [FIX] Reduced reliance on user-specific absolute paths in instructions.
  - [FIX] Improved predictability for mixed interactive and CLI automation use.

### Unchanged
- build_title_editor_batch_from_release_notes.sh
- setup_jamf_pro_credentials.sh
- setup_title_editor_credentials.sh
- build_title_editor_batch_from_github.sh
- build_title_editor_batch_from_jamf_patch_catalog.sh
- title_editor_api_ctrl.sh
- title_editor_software_title_defaults_from_user_prompt.sh
- update_title_editor_versions.sh
