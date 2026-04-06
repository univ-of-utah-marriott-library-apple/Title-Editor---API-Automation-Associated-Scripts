## Release Notes
Release date: 2026-04-06

Summary:
- Added files: 0
- Updated files: 0
- Unchanged files: 9
- Target-only files: 0

### Highlights
- [UNCHANGED] No file changes detected in this sync.
- build_title_editor_batch_from_release_notes.sh:
  - [INFO] Improved release-notes and Mac App Store extraction logic to better detect valid versions.
  - [INFO] Normalized version ordering so newest versions are prioritized in batch output.
  - [INFO] Reduced stale-version selection risk when source pages mix old/new version blocks.
  - [INFO] Hardened fallback parsing for pages with irregular HTML structures.
  - [INFO] Improved consistency of short-format batch file generation.
- setup_jamf_pro_credentials.sh:
  - [INFO] Improved Jamf Pro API credential setup and secure keychain storage workflow.
  - [INFO] Added credential verification flow to reduce failed API auth during automation runs.
  - [INFO] Improved operator prompts and guidance for safer setup in user context.
  - [INFO] Reduced manual environment-variable handling by standardizing secure credential loading.
- setup_title_editor_credentials.sh:
  - [INFO] Enhanced setup/verify/migrate credential workflows for safer operations.
  - [INFO] Improved keychain diagnostics to avoid exposing plaintext sensitive values.
  - [INFO] Clarified verification error messaging and next-step recovery guidance.
  - [INFO] Improved migration checks for partial credential states.
  - [INFO] Reduced user-specific path leakage in help output.
- build_title_editor_batch_from_github.sh:
  - [INFO] Refined GitHub release/tag discovery and parsing for mixed naming conventions.
  - [INFO] Improved latest-version detection across repos that publish both tags and releases.
  - [INFO] Reduced false positives from prerelease/label noise in release metadata.
  - [INFO] Improved resilience when repo APIs return sparse or irregular fields.
  - [INFO] Kept generated batch rows aligned with expected Title Editor import format.
- build_title_editor_batch_from_jamf_patch_catalog.sh:
  - [INFO] Improved Jamf Patch OAuth credential handling and token retrieval flow.
  - [INFO] Improved keychain/env credential fallback behavior for non-interactive runs.
  - [INFO] Refined patch-title lookup path to reduce lookup mismatches.
  - [INFO] Improved normalization of extracted versions before batch output.
  - [INFO] Kept output formatting consistent for downstream Title Editor batch imports.
- title_editor_menu.sh:
  - [INFO] Improved menu integration with API/auth helper routines.
  - [INFO] Refined reconnect behavior after token expiry during menu operations.
  - [INFO] Improved keychain-assisted login fallback paths.
  - [INFO] Reduced reliance on user-specific absolute paths in instructions.
  - [INFO] Improved predictability for mixed interactive and CLI automation use.
- title_editor_api_ctrl.sh:
  - [INFO] Hardened API connection and auth token lifecycle handling.
  - [INFO] Improved refresh/keepalive/expiry behavior for long-running sessions.
  - [INFO] Reduced edge-case failures when reconnecting after token expiration.
  - [INFO] Updated examples to use placeholder-safe credential values.
  - [INFO] Improved reliability for non-interactive scripted API workflows.
- title_editor_software_title_defaults_from_user_prompt.sh:
  - [INFO] Refined prompt default logic for software-title mapping.
  - [INFO] Improved consistency for user-entered names resolving to expected titles.
  - [INFO] Reduced mismatch risk when title aliases are used in prompts.
  - [INFO] Improved behavior for non-interactive/default-driven executions.
- update_title_editor_versions.sh:
  - [INFO] Strengthened end-to-end update orchestration across source->batch->import flow.
  - [INFO] Improved source fetch validation before writing batch output.
  - [INFO] Refined sequencing for generation/import/state update steps.
  - [INFO] Improved mismatch visibility in logs when data sources disagree.
  - [INFO] Improved consistency of latest-version extraction from generated batch files.

### Unchanged
- build_title_editor_batch_from_release_notes.sh
- setup_jamf_pro_credentials.sh
- setup_title_editor_credentials.sh
- build_title_editor_batch_from_github.sh
- build_title_editor_batch_from_jamf_patch_catalog.sh
- title_editor_menu.sh
- title_editor_api_ctrl.sh
- title_editor_software_title_defaults_from_user_prompt.sh
- update_title_editor_versions.sh
