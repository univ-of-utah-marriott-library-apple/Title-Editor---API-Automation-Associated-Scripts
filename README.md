# Title Editor - API Automation

## Table of Contents

- [Release Notes Update (2026-04-03)](#release-notes-update-2026-04-03)
- [Introduction and Background](#introduction-and-background)
- [Installation and Setup](#installation-and-setup)
- [Quick Start](#quick-start)
- [Script Reference](#script-reference)
- [Workflow: Title Editor with Jamf Pro Patch Management](#workflow-title-editor-with-jamf-pro-patch-management)
- [Installomator: Patch Compliance for Open-Source and Common Applications](#installomator-patch-compliance-for-open-source-and-common-applications)
- [Restricted and Campus-Only Applications](#restricted-and-campus-only-applications)
- [Mac App Store Applications — Repackaging and Post-Install Automation](#mac-app-store-applications--repackaging-and-post-install-automation)
- [Quick Reference](#quick-reference)

---

## Release Notes Update (2026-04-03)

### Scripts included in this update

- `build_title_editor_batch_from_github.sh`
- `build_title_editor_batch_from_jamf_patch_catalog.sh`
- `build_title_editor_batch_from_release_notes.sh`
- `setup_title_editor_credentials.sh`
- `title_editor_api_ctrl.sh`
- `title_editor_menu.sh`
- `title_editor_software_title_defaults_from_user_prompt.sh`
- `update_title_editor_versions.sh`

### Why `build_title_editor_batch_from_jamf_patch_catalog.sh` exists

`build_title_editor_batch_from_jamf_patch_catalog.sh` primarily exists to help resolve Jamf Patch Extension Attribute (EA) issues where applications are installed in a sub-folder under `/Applications` (for example `/Applications/Web Browsers`).

Example Jamf Patch EA for Opera:

```sh
#!/bin/bash
####################################################
# A script to collect the Bundle Version of Opera. #
####################################################
PATH_EXPR=(/Applications/*/Contents/MacOS/Opera)
KEY="CFBundleVersion"
IFS=$'\n'
unset RESULTS
for BINARY in "${PATH_EXPR[@]}"; do
    PLIST=$(/usr/bin/dirname "${BINARY}")/../Info.plist
    VERSION=$(/usr/bin/defaults read "${PLIST}" "${KEY}" 2>/dev/null)
    if [ -n "${VERSION}" ] ; then
        RESULTS+=("${VERSION}")
    fi
done
unset IFS
if [ ${#RESULTS[*]} -eq 0 ]; then
    /bin/echo "<result></result>"
else
    IFS="|"
    /bin/echo "<result>|${RESULTS[*]}|</result>"
    unset IFS
fi
exit 0
```

Needed EA in Title Editor context (specific subfolder + bundle ID check):

```sh
#!/bin/sh
####################################################
# A script to collect the Bundle Version of Opera. #
####################################################
PATH_EXPR="/Applications/Web\ Browsers/*/Contents/MacOS/Opera"
BUNDLE_ID="com.operasoftware.Opera"
KEY="CFBundleVersion"
RESULTS=()
IFS=$'\n'
for BINARY in ${PATH_EXPR}; do
    PLIST="$(/usr/bin/dirname "${BINARY}")/../Info.plist"
    if [ "$(/usr/bin/defaults read "${PLIST}" CFBundleIdentifier 2>/dev/null)" == "${BUNDLE_ID}" ]; then
        RESULTS+=($(/usr/bin/defaults read "${PLIST}" "${KEY}" 2>/dev/null))
    fi
done
unset IFS
if [ ${#RESULTS[@]} -eq 0 ]; then
    /bin/echo "<result></result>"
else
    IFS="|"
    /bin/echo "<result>${RESULTS[*]}</result>"
    unset IFS
fi
exit 0
```

---

## Introduction and Background

### The Marriott Library Mac Fleet

The J. Willard Marriott Library at the University of Utah manages one of the larger academic Mac fleets in the Intermountain West. The IT department is responsible for deploying, maintaining, and keeping current thousands of macOS endpoints across public computing labs, faculty and staff workstations, specialized media production suites, and administrative offices. Software spans a wide spectrum: common open-source utilities, campus-licensed applications distributed under enterprise agreements, paid professional creative tools, and internally developed software.

Ensuring every Mac runs the correct, up-to-date version of every managed application — with full visibility into what is installed where — is a core operational objective. Jamf Pro is the MDM platform. The core patch visibility and compliance layer is Jamf Pro Patch Management, extended via Jamf Title Editor.

---

### Jamf Pro Patch Management: Compliance, Reporting, and Patch Enforcement

Jamf Pro Patch Management is the built-in feature of Jamf Pro responsible for **tracking software versions across the Mac fleet, reporting on patch compliance, and actively patching out-of-date machines.** It gives IT administrators a real-time dashboard showing every managed application — what version each Mac is running, whether it is current, and how many machines need attention. It sends notifications when new versions are released and executes Patch Policies that install updated software on out-of-date machines.

**Patch Policies** are where the active patching happens. A Patch Policy links an installer package to a specific software version, scopes the deployment to a target group of computers, and gives IT full control over the update experience for end users:

- **Deadlines** — a hard cutoff date and time after which the update installs automatically, regardless of whether the user has acted.
- **Deferral limits** — how many times a user may postpone a prompted update before it becomes mandatory.
- **Grace periods** — the window of time a user gets to save work and quit the application after the final deferral, before the installer runs automatically.
- **User-facing notifications** — customizable messaging at each deferral prompt and during the grace-period countdown, so users know what is being updated and when.
- **Patch scope** — smart group targeting ensures the policy reaches only machines that need it, and the compliance dashboard updates in real time as machines patch successfully.

Patch Management works from **patch sources** — catalogs of software title definitions that describe what versions of an application exist and how to detect them on a managed Mac. Jamf Pro ships with a built-in internal patch source (the Jamf-curated catalog) covering a wide range of common third-party applications. For software not covered by that catalog, administrators can register additional **external patch sources**. Jamf Title Editor is one such external patch source.

> **Core value of Patch Management:** The full lifecycle from visibility to enforcement — a compliance dashboard showing every application across the fleet, combined with Patch Policies that deliver updates on IT-defined schedules with configurable deadlines, deferral limits, grace periods, and user notifications that balance urgency with end-user experience.

---

### Jamf Title Editor: Extending the Patch Management Catalog

**Jamf Title Editor is a separate, Jamf-hosted service** — with its own URL, user management, web interface, and REST API — that **extends Jamf Pro Patch Management** by acting as a custom external patch source. It was built on Kinobi technology acquired from Mondada and released by Jamf in 2021.

Once Title Editor is registered in Jamf Pro's Patch Management settings, every software title and version record defined in Title Editor becomes available inside Jamf Pro Patch Management exactly like a built-in catalog entry — appearing in the compliance dashboard, triggering notifications, and supporting Patch Policies. Title Editor makes it possible to add any application to the Jamf Pro patch compliance workflow, regardless of whether Jamf's own catalog covers it.

Title Editor does not deploy software itself. It provides the patch definitions — the title records and version histories — that Jamf Pro Patch Management needs to track compliance and drive Patch Policies. The IT team still builds and uploads the installer packages that those policies distribute.

---

### Jamf Pro App Installers: A Separate Deployment Mechanism

Jamf Pro App Installers (the Jamf App Catalog) is a distinct, modern deployment mechanism where Jamf sources, packages, signs, and hosts installers for a large catalog of popular publicly available applications. For supported titles, the admin simply scopes the deployment and Jamf handles the rest — no package management required.

App Installers are excellent for common public software like Google Chrome, Slack, or Zoom. They are not available for **campus-restricted software** behind vendor portals, **paid Mac App Store titles** requiring custom post-install setup, or **any application not in Jamf's hosted catalog.** For those cases, the Marriott Library IT team uses Title Editor to bring those applications into the Jamf Pro Patch Management compliance dashboard.

> **Relationship summary:** Title Editor extends Jamf Pro Patch Management to cover any application — it adds custom titles to the compliance dashboard and drives Patch Policies for software the built-in Jamf catalog or App Installers do not cover. The three systems are complementary: App Installers for hands-off public-app delivery; Patch Management for compliance visibility, active patching, and policy enforcement with deadlines and user notifications; and Title Editor to fill the gaps in the patch catalog.

---

### The Three Categories of Title Editor Use at Marriott Library

The Marriott Library IT team uses Title Editor for three distinct categories of application:

| Category | Description | Documentation |
|---|---|---|
| **Installomator-managed applications** | Open-source and common applications where Installomator handles silent download and installation. Title Editor provides the patch compliance dashboard — showing installed versions across the fleet and enabling Patch Policies to enforce upgrades. | Section 6 |
| **Restricted / campus-only applications** | Software distributed exclusively through vendor portals or campus licensing agreements (e.g. Palo Alto Networks GlobalProtect). Not available in any Jamf catalog. Title Editor is the only path to patch compliance tracking for these titles. | Section 7 |
| **Repackaged Mac App Store applications** | Paid or complex MAS titles (Xcode, Final Cut Pro, Logic Pro, GarageBand) that require post-install scripting or customization that Jamf Pro's MDM-based App Store deployment cannot provide. Repackaged as PKGs and managed through Jamf Pro Patch Management with Title Editor providing the version catalog. | Section 8 |

---

### The Title Editor Automation Toolkit

Title Editor exposes a comprehensive REST API. The Marriott Library IT team has developed a suite of open-source Bash scripts to automate the most common workflows against this API.

| Script | Purpose |
|---|---|
| `title_editor_api_ctrl.sh` | Core API library. Must be sourced by all other scripts. Manages authentication, Bearer token lifecycle (with background keep-alive), and all HTTP operations against the Title Editor REST API. |
| `setup_title_editor_credentials.sh` | One-time credential wizard. Stores the Title Editor hostname, username, and password securely in the macOS Login Keychain under the service name `TitleEditorAPI`. |
| `title_editor_menu.sh` | Interactive CLI menu and full non-interactive CLI. Browse titles, view patch version details, add versions individually or in batch, create new titles, export title JSON. |
| `build_title_editor_batch_from_github.sh` | Queries a GitHub repository's releases or tags and generates a batch import file for bulk version history population. |
| `build_title_editor_batch_from_jamf_patch_catalog.sh` | Pulls software version data from Jamf Patch sources and generates a Title Editor batch import file, including workflows helpful for subfolder app install path edge cases. |
| `build_title_editor_batch_from_release_notes.sh` | Scrapes a vendor release-notes web page or the Mac App Store version history and generates a batch import file. |
| `title_editor_software_title_defaults_from_user_prompt.sh` | Prompts for software title metadata defaults and helps standardize values used when creating/importing Title Editor records. |
| `update_title_editor_versions.sh` | Wrapper orchestration script that checks sources, builds/imports batch updates, and tracks current-version state across managed titles. |

---

## Installation and Setup

### Prerequisites

| Dependency | Notes |
|---|---|
| macOS | macOS 12 Monterey or later (scripts use standard POSIX Bash constructs) |
| Bash | System Bash 3.2+ or Homebrew Bash 5.x (recommended for Unicode handling) |
| curl | Installed by default on all macOS versions; used for all HTTP requests |
| python3 | macOS 12+ includes Python 3.9+; used for JSON parsing in batch operations |
| jq (optional) | More robust JSON parsing; scripts fall back to grep/sed when absent |
| Jamf Pro + Title Editor | Active Jamf Pro with Title Editor provisioned as an external patch source in Patch Management settings |
| Title Editor credentials | Account on the Title Editor instance with permission to create and manage software titles |

---

### Script Placement

Place all toolkit scripts in a single working directory. The API library (`title_editor_api_ctrl.sh`) is located automatically if it is in the same directory as `title_editor_menu.sh`, in `$HOME`, or in `/usr/local/bin`.

```bash
mkdir -p ~/title_editor
# Copy all toolkit scripts into ~/title_editor/
chmod +x ~/title_editor/*.sh
```

---

### Storing Credentials

Run the credentials wizard once per workstation. It stores the Title Editor server hostname, API username, and password as separate entries in the macOS Login Keychain.

```bash
bash ~/title_editor/setup_title_editor_credentials.sh

# Verify stored credentials against the live Title Editor API
bash ~/title_editor/setup_title_editor_credentials.sh --verify

# Debug mode: shows password fingerprint/length, never plaintext
bash ~/title_editor/setup_title_editor_credentials.sh --verify --debug
```

---

### Optional: Configuration File

Connection parameters can also be stored in a plain-text config file. The API library reads `/etc/title_editor_api.conf` (system-wide) or `~/.title_editor_api.conf` (per-user). Passwords are never stored in config files — only in the Keychain or via the `TITLE_EDITOR_API_PW` environment variable.

```ini
# ~/.title_editor_api.conf
title_editor_server_name: yourorg.appcatalog.jamfcloud.com
title_editor_username:    apiuser
title_editor_verify_cert: true
title_editor_timeout:     60
```

---

## Quick Start

This section shows the fastest path from zero to a working Title Editor software title in Jamf Pro Patch Management. Complete Installation and Setup (Section 2) first, then follow the scenario that matches your application type.

---

### Quick Start: Add a New Release to an Existing Title

The most common day-to-day task — a new version of an already-tracked application is released and needs a version record in Title Editor so Jamf Pro Patch Management can begin targeting it.

```bash
# Authenticate
source ~/title_editor/title_editor_api_ctrl.sh

# Add the new version record (all other fields inherit from the last patch)
bash ~/title_editor/title_editor_menu.sh \
  --add-patch \
  --title-name "Palo Alto GlobalProtect" \
  --version "6.3.0" \
  --yes

# Done. Jamf Pro Patch Management picks up the new version on its next
# patch feed refresh (~30 minutes). Upload and attach the package in
# Jamf Pro Patch Management to activate the Patch Policy.
```

---

### Quick Start: Brand-New Title from a GitHub Repository

Setting up a completely new software title for an open-source application that publishes releases on GitHub — for example, draw.io (diagrams.net), a widely used diagramming tool.

```bash
# Step 1 — Build a version history batch file from GitHub releases
bash ~/title_editor/build_title_editor_batch_from_github.sh \
  --repo jgraph/drawio-desktop \
  --title-name "draw.io" \
  --limit 10 \
  --output ~/title_editor/batches/drawio.txt

# Step 2 — Authenticate, create the title, then import version history
source ~/title_editor/title_editor_api_ctrl.sh

bash ~/title_editor/title_editor_menu.sh \
  --create-title \
  --title-name "draw.io" \
  --publisher "JGraph Ltd" \
  --bundle-id "com.jgraph.drawio.desktop" \
  --version "24.5.3" \
  --yes

bash ~/title_editor/title_editor_menu.sh \
  --add-patch-batch \
  --file ~/title_editor/batches/drawio.txt

# Step 3 — In Jamf Pro: Computers > Patch Management
#   > Add Software Title > select the Title Editor external source
#   > find "draw.io" > configure and attach your package
```

---

### Quick Start: Brand-New Title from a Vendor Release-Notes Page

Setting up a new software title for an application whose version history lives on a vendor release-notes page — for example, Mactracker, a popular Mac reference app with a public release-notes page.

```bash
# Step 1 — Scrape version history from the Mactracker release-notes page
bash ~/title_editor/build_title_editor_batch_from_release_notes.sh \
  --url "https://mactracker.ca/releasenotes-mac.html" \
  --title-name "Mactracker" \
  --limit 10 \
  --output ~/title_editor/batches/mactracker.txt

# Step 2 — Create the title and import version history
source ~/title_editor/title_editor_api_ctrl.sh

bash ~/title_editor/title_editor_menu.sh \
  --create-title \
  --title-name "Mactracker" \
  --new-title-id mactracker \
  --publisher "Ian Page" \
  --bundle-id ca.mactracker.Mactracker \
  --version 7.13 \
  --yes

bash ~/title_editor/title_editor_menu.sh \
  --add-patch-batch \
  --file ~/title_editor/batches/mactracker.txt

# Step 3 — In Jamf Pro: attach the tested PKG to the version record
#   and scope the Patch Policy to eligible machines.
```

---

### Quick Start: Brand-New Title from Jamf Patch Catalog

Use this flow when Jamf Patch catalog data is the best source of version history, especially where patch metadata and real install-path behavior need alignment before Title Editor import.

```bash
# Step 1 — Build version history from Jamf Patch catalog data
bash ~/title_editor/build_title_editor_batch_from_jamf_patch_catalog.sh \
  --source jamf-pro \
  --software-name "Opera (Jamf)" \
  --title-name "Opera" \
  --limit all \
  --output ~/title_editor/batches/opera_from_jamf.txt

# Step 2 — Create the title and import batch versions
source ~/title_editor/title_editor_api_ctrl.sh

bash ~/title_editor/title_editor_menu.sh \
  --create-title \
  --title-name "Opera" \
  --new-title-id opera \
  --publisher "Opera" \
  --bundle-id com.operasoftware.Opera \
  --version 120.0.5543.93 \
  --yes

bash ~/title_editor/title_editor_menu.sh \
  --add-patch-batch \
  --file ~/title_editor/batches/opera_from_jamf.txt

# Step 3 — In Jamf Pro: configure from Title Editor source,
# attach tested package, and scope Patch Policy deployment.
```

---

### Quick Start: Brand-New Title from the Mac App Store

Setting up a repackaged MAS application — for example, Final Cut Pro — where the version history is pulled from the App Store listing.

```bash
# Step 1 — Retrieve version history from the Mac App Store
bash ~/title_editor/build_title_editor_batch_from_release_notes.sh \
  --mac-app-store \
  --mac-app-store-name "Final Cut Pro" \
  --title-name "Final Cut Pro" \
  --output ~/title_editor/batches/finalcutpro.txt
# Script searches the App Store, presents matching listings,
# and auto-populates bundle ID (com.apple.FinalCut) on confirmation.

# Step 2 — Create title and import version history
source ~/title_editor/title_editor_api_ctrl.sh

bash ~/title_editor/title_editor_menu.sh \
  --create-title \
  --title-name "Final Cut Pro" \
  --publisher Apple \
  --bundle-id com.apple.FinalCut \
  --version "11.0" \
  --yes

bash ~/title_editor/title_editor_menu.sh \
  --add-patch-batch \
  --file ~/title_editor/batches/finalcutpro.txt

# Step 3 — In Jamf Pro: attach the repackaged Final Cut Pro PKG
#   (with post-install script) to the version record.
```

---

### Quick Start: Preview Before Committing

Before running any batch import against a live Title Editor instance, use `--dry-run` to validate the file and confirm what would be created without writing anything.

```bash
source ~/title_editor/title_editor_api_ctrl.sh

# Preview a batch — no changes are written
bash ~/title_editor/title_editor_menu.sh \
  --add-patch-batch \
  --file ~/title_editor/batches/globalprotect.txt \
  --dry-run

# Validate a single patch without creating it
bash ~/title_editor/title_editor_menu.sh \
  --add-patch \
  --title-name "Palo Alto GlobalProtect" \
  --version 6.2.5 \
  --dry-run
```

---

## Script Reference

### `title_editor_api_ctrl.sh` — API Library

This script must be **sourced** (not executed) before any other script in the toolkit runs. It manages the full API session lifecycle: reading credentials from the Keychain or config file, authenticating to Title Editor and obtaining a Bearer token, running a background keep-alive process that refreshes the token 5 minutes before expiry (critical for long batch operations), and performing all HTTP operations. If a token expires mid-operation, the calling script detects the error and attempts a reconnect before retrying.

```bash
source ~/title_editor/title_editor_api_ctrl.sh

title_editor_api_connect                      # authenticate using Keychain credentials
title_editor_api_list_titles                  # list all titles in Title Editor
title_editor_api_get "softwaretitles/42"      # fetch full details for a title
title_editor_api_disconnect                   # clear token state and end session
```

---

### `title_editor_menu.sh` — Interactive Menu and CLI

Provides both a navigable interactive terminal menu and a complete non-interactive CLI for automation. In interactive mode, administrators can browse all software titles, review patch version histories, inspect kill-app and component definitions, add new patch versions, and export title JSON.

```bash
source ~/title_editor/title_editor_api_ctrl.sh
bash ~/title_editor/title_editor_menu.sh
```

#### Create a New Software Title

```bash
source ~/title_editor/title_editor_api_ctrl.sh
bash ~/title_editor/title_editor_menu.sh \
  --create-title \
  --title-name "Palo Alto GlobalProtect" \
  --new-title-id globalprotect \
  --publisher "Palo Alto Networks" \
  --bundle-id com.paloaltonetworks.globalprotect \
  --version 6.2.4 \
  --yes
```

#### Add a Single Patch Version

Used when a new release needs one new version record. All fields other than `--version` are inherited from the most recent existing patch definition.

```bash
source ~/title_editor/title_editor_api_ctrl.sh
bash ~/title_editor/title_editor_menu.sh \
  --add-patch \
  --title-name "Palo Alto GlobalProtect" \
  --version 6.2.5 \
  --yes
```

| Flag | Description |
|---|---|
| `--title-id <n>` | Target title by numeric ID (alternative to `--title-name`) |
| `--title-name <n>` | Target by display name (case-insensitive, must resolve uniquely) |
| `--version <ver>` | Version string to create (**required**) |
| `--release-date <ISO>` | Override release date (default: current UTC timestamp) |
| `--min-os <ver>` | Minimum macOS version (default: from most recent patch) |
| `--bundle-id <id>` | App bundle ID (default: from most recent patch) |
| `--app-name <n>` | App display name for kill-apps definition |
| `--yes` | Skip interactive confirmation prompt |
| `--dry-run` | Preview what would be created without writing anything |
| `--verify-only` | Validate resolution only — no changes, no confirmation |

#### Batch Import — Multiple Patch Versions

Reads a pipe-delimited file and creates multiple patch version records in a single operation. The primary mechanism for bulk-populating version histories.

```bash
source ~/title_editor/title_editor_api_ctrl.sh
bash ~/title_editor/title_editor_menu.sh \
  --add-patch-batch \
  --file /path/to/batch.txt
```

**Short format** (produced by the batch-builder scripts — sufficient for most cases):

```
# title_name|version
# Lines beginning with # are comments and are skipped
Palo Alto GlobalProtect|6.2.3
Palo Alto GlobalProtect|6.2.4
Palo Alto GlobalProtect|6.2.5
```

**Full format** (explicit control over every field):

```
# title_id|title_name|version|release_date|min_os|standalone|reboot|bundle_id|app_name|yes
|Palo Alto GlobalProtect|6.2.5|2024-03-15T00:00:00Z|13.0|yes|no|com.paloaltonetworks.globalprotect|GlobalProtect|yes
```

**Batch processing details:**

- Versions are processed oldest-to-newest per title so that `currentVersion` ends up at the most recent after all inserts.
- Versions already present in Title Editor are silently skipped — safe to re-run with the same file.
- After each batch run, touched titles are automatically resequenced for correct ordering in the Jamf Pro Patch Management web UI.
- `--start-line` and `--max-rows` allow resuming a partial batch or processing a file in chunks.
- `--dry-run` previews all actions without writing.

> **Batch text file vs. JSON import — which to use?**
>
> Use the **batch text file** (`title_name|version`) when the software title already exists in Title Editor and you are adding version records to it. The API batch mode is incremental — it adds only what is missing, skips duplicates, and is safe to re-run.
>
> Use the **JSON import file** (`--output-json` / `--json`) when you are creating a brand-new title and its full version history in a single step, or when transferring a complete title definition between Title Editor instances. The JSON file contains the full title definition including publisher, bundle ID, kill-app definitions, and all patch versions — it is imported through the Title Editor web UI rather than the CLI batch command.
>
> **Rule of thumb:** batch text for ongoing version updates to existing titles; JSON for new title creation or Title Editor instance migration.

#### Additional CLI Modes

```bash
# Export a title definition to a portable JSON file
bash title_editor_menu.sh --export-title-json --title-name "App" --output title.json

# Resequence existing patches newest-first
bash title_editor_menu.sh --resequence-only --title-name "App" --yes

# Remove patches with non-semantic version strings (dry run first)
bash title_editor_menu.sh --cleanup-non-semver --title-name "App" --dry-run
bash title_editor_menu.sh --cleanup-non-semver --title-name "App" --yes
```

---

### `build_title_editor_batch_from_github.sh`

Queries the GitHub API for the release or tag history of any public repository and produces a batch import file. The primary tool for back-populating version histories for open-source applications hosted on GitHub.

```bash
# Interactive mode (prompts for repo, title name, output path)
bash ~/title_editor/build_title_editor_batch_from_github.sh

# Non-interactive — plain text batch output
bash ~/title_editor/build_title_editor_batch_from_github.sh \
  --repo microsoft/vscode \
  --title-name "Visual Studio Code" \
  --limit 20 \
  --output ~/title_editor/batches/vscode.txt

# JSON import file (useful when also creating the title)
bash ~/title_editor/build_title_editor_batch_from_github.sh \
  --repo microsoft/vscode \
  --title-name "Visual Studio Code" \
  --bundle-id com.microsoft.VSCode \
  --app-name Code \
  --publisher Microsoft \
  --min-os 11.0 \
  --output-json ~/title_editor/json/vscode.json
```

- `--source auto|releases|tags` — defaults to GitHub Releases API; falls back to repository tags if no formal releases exist.
- Pre-release, draft, and beta/alpha/rc-labelled versions are excluded by default; use `--include-prerelease` to include them.
- On repositories with macOS-specific tags prefixed `mac-`, those are preferred automatically.
- Set `GH_TOKEN` in the environment to raise the rate limit from 60 to 5,000 GitHub API requests/hour.

---

### `build_title_editor_batch_from_release_notes.sh`

Fetches a vendor release-notes web page or queries the Mac App Store and extracts version strings from headings and table rows. Used for applications whose version history is best sourced from a vendor support page rather than GitHub.

```bash
# Vendor release-notes page
bash ~/title_editor/build_title_editor_batch_from_release_notes.sh \
  --url "https://docs.paloaltonetworks.com/globalprotect/6-2/globalprotect-release-notes" \
  --title-name "Palo Alto GlobalProtect" \
  --limit 10 \
  --output ~/title_editor/batches/globalprotect.txt

# Mac App Store mode — auto-populates bundle ID from App Store listing metadata
bash ~/title_editor/build_title_editor_batch_from_release_notes.sh \
  --mac-app-store \
  --mac-app-store-name "Final Cut Pro" \
  --title-name "Final Cut Pro" \
  --output ~/title_editor/batches/finalcutpro.txt
```

Use `--debug` for verbose HTML parsing output when a vendor changes page layout and version extraction breaks.

---

### `build_title_editor_batch_from_jamf_patch_catalog.sh`

Builds a Title Editor batch file from Jamf Patch catalog data (Jamf Pro API or exported patch XML), useful when Jamf patch metadata and live install-path detection need to be reconciled.

```bash
# Build from Jamf Pro patch title name
bash ~/title_editor/build_title_editor_batch_from_jamf_patch_catalog.sh \
  --source jamf-pro \
  --software-name "Opera (Jamf)" \
  --title-name "Opera" \
  --output ~/title_editor/batches/opera_from_jamf.txt
```

- Supports credential sourcing from environment and/or Keychain.
- Helpful for applications installed under subdirectories (for example `/Applications/Web Browsers`).

---

### `title_editor_software_title_defaults_from_user_prompt.sh`

Prompts for common software-title defaults and outputs normalized values that can be reused when creating or updating Title Editor software title records.

```bash
bash ~/title_editor/title_editor_software_title_defaults_from_user_prompt.sh
```

Use this helper when standardizing title naming, bundle ID conventions, and publisher values before import or API create/update operations.

---

### `update_title_editor_versions.sh`

Wrapper/orchestration script for repeatable version checks and updates across multiple software titles and source types (GitHub, release notes, Mac App Store, Jamf patch sources).

```bash
# Check one item (no import/state write)
bash ~/title_editor/update_title_editor_versions.sh \
  --item amphetamine \
  --current-only \
  --no-import \
  --no-apply
```

- Supports one-item or all-item runs.
- Maintains per-item/version state keys.
- Integrates with existing batch builder scripts and Title Editor import flow.

---

## Workflow: Title Editor with Jamf Pro Patch Management

### How a Title Editor Definition Drives Patch Management

Once Title Editor is registered as an external patch source in Jamf Pro, software titles defined in Title Editor appear natively in the Jamf Pro Patch Management interface. The workflow for getting a new application onto the compliance dashboard is:

1. In Title Editor, create the software title (`--create-title`), providing the application name, publisher, and bundle ID.
2. Back-populate historical version records using the appropriate batch-builder script, then import the batch with `--add-patch-batch`. Each version record tells Jamf Pro what versions of the application are known to exist.
3. In Jamf Pro (**Computers > Patch Management**), configure the software title from the Title Editor external source. Jamf Pro reads the version list from Title Editor and begins showing the application in the compliance dashboard — immediately displaying which machines have it installed and at what version.
4. Upload the tested installer package to Jamf Pro. In the Patch Management software title configuration, attach the package to the appropriate version record.
5. Create a Patch Policy: define scope (smart group), grace period, notification behaviour, and deferral settings. The Patch Policy will install the package on machines where the installed version is older than the target.
6. For each new release: run `--add-patch` to add the version record to Title Editor, upload the updated package to Jamf Pro, and attach it. The existing Patch Policy automatically begins targeting the new version.

> **Dashboard value:** As soon as a software title has version records in Title Editor and is configured in Jamf Pro Patch Management, the compliance dashboard populates — showing every Mac with the application installed, at what version, and whether it is current. This visibility exists even before any Patch Policy is created. Once a Patch Policy is configured, Patch Management actively delivers updates to non-compliant machines with IT-defined deadlines, deferral limits, grace periods, and user-facing notifications.

---

### Version Ceiling and Staged Rollouts

Title Editor's `currentVersion` field gives IT explicit control over which version Jamf Pro treats as the upgrade target. This is important for applications where new versions require testing before broad rollout:

- Add a new version record to Title Editor without changing `currentVersion`. The version is in the history but is not yet the patch target.
- Create a narrow, pilot-scoped Patch Policy pointing at the new version. Test with a small group.
- Once testing passes, update `currentVersion` (`--add-patch` does this automatically on a successful create, or update it via the Title Editor web UI). The main Patch Policy now enforces the new version fleet-wide.

---

## Installomator: Patch Compliance for Open-Source and Common Applications

### What is Installomator?

Installomator (`github.com/Installomator/Installomator`) is an open-source Bash script maintained by the Mac admin community. It contains download-and-install recipes for hundreds of macOS applications. When called with an application label from a Jamf Pro Policy script payload, Installomator locates the current download URL from the vendor's public distribution endpoint, verifies the code signature, and silently installs the application — without the IT team building or hosting a package.

Installomator is used at Marriott Library IT as the installation and update mechanism for a large class of publicly available applications. Installomator handles the delivery; Title Editor provides the version catalog that gives Jamf Pro Patch Management the data it needs to produce a useful compliance dashboard.

---

### Why Title Editor is Still Needed Alongside Installomator

Installomator installs whatever the current version of an application is at the time it runs — it has no awareness of version targets, no compliance reporting, and no enforcement mechanism. Without Title Editor providing version records, Jamf Pro Patch Management has no way to know **what version an Installomator-managed application should be at, which machines are behind, or how many machines across the fleet have it installed at all.**

Title Editor closes that gap. By maintaining version records in Title Editor for each Installomator-managed application, the Marriott Library IT team gets:

- A real-time compliance dashboard in Jamf Pro showing every Mac with the application installed, the installed version, and whether it is current.
- Patch notifications when a new version is added to Title Editor.
- Patch Policies that identify out-of-date machines and trigger the Installomator-based Jamf Pro Policy as the remediation action.

> **Note on App Installers and the built-in Jamf catalog:** Some Installomator-managed applications also appear in Jamf's built-in Patch Management catalog or App Installers. Marriott Library IT may use Title Editor instead of or alongside these to gain greater control over the `currentVersion` ceiling, kill-app definitions, or customized criteria — capabilities Title Editor exposes through its API that the built-in catalog does not.

---

### The Installomator + Title Editor Pattern

1. A Jamf Pro Policy invokes Installomator as its script payload to silently install or update the application.
2. A Title Editor software title tracks known versions of the application. New versions are added using `--add-patch` or the batch builders.
3. Jamf Pro Patch Management uses the Title Editor version records to display the compliance dashboard and identify out-of-date machines.
4. A Jamf Pro Patch Policy backed by the Title Editor source calls the Installomator-based policy as its remediation action, enforcing upgrades on non-compliant machines.

---

### Example — draw.io

#### Jamf Pro Policy: Install via Installomator

```bash
#!/bin/bash
# Jamf Pro Policy — Script payload
# Silently installs or updates draw.io using Installomator

/usr/local/bin/installomator.sh drawio \
  NOTIFY=silent \
  BLOCKING_PROCESS_ACTION=tell_user

exit $?
```

#### Populate Title Editor Version History

```bash
bash ~/title_editor/build_title_editor_batch_from_github.sh \
  --repo jgraph/drawio-desktop \
  --title-name "draw.io" \
  --source releases \
  --output ~/title_editor/batches/drawio.txt

source ~/title_editor/title_editor_api_ctrl.sh
bash ~/title_editor/title_editor_menu.sh \
  --add-patch-batch \
  --file ~/title_editor/batches/drawio.txt
```

---

### Sample Installomator + Title Editor Applications at Marriott Library

| Application | Installomator / Title Editor Integration |
|---|---|
| Zoom | Installomator label: `zoom`. Version history scraped from Zoom's release notes page. |
| Slack | Installomator label: `slack`. GitHub releases tracked via the batch builder. |
| Microsoft Teams | Installomator label: `microsoftteams`. Version history from Microsoft's release notes page. |
| Jamf Connect | Installomator label: `jamfconnect`. Title manually created; versions added as each release is announced. |
| Suspicious Package | Installomator label: `suspiciouspackage`. GitHub releases parsed with the batch builder. |
| BBEdit | Installomator label: `bbedit`. GitHub release tags populate version history. |


---

## Restricted and Campus-Only Applications

### Overview

A significant category of software in an academic environment is distributed exclusively through vendor portals or institutional licensing agreements. New version information for these applications is not publicly available, which means they cannot appear in Jamf's built-in Patch Management catalog, cannot be delivered by App Installers, and cannot be tracked by Installomator. Title Editor is the only available mechanism for bringing these applications into the Jamf Pro patch compliance dashboard.

The IT team sources the installer directly from the vendor portal, builds and tests the package, and uploads it to Jamf Pro. Title Editor provides the patch definition that makes the application visible and enforceable in Jamf Pro Patch Management.

---

### Palo Alto Networks GlobalProtect — Worked Example

GlobalProtect is the University of Utah's campus VPN client, provided under an enterprise agreement with Palo Alto Networks and distributed from the Palo Alto customer support portal. It is not publicly redistributable. Marriott Library IT is responsible for deploying GlobalProtect to all managed Macs and keeping it current across thousands of endpoints.

Because the installer is behind a customer portal, GlobalProtect cannot appear in Jamf App Installers, the built-in Jamf Patch Management catalog, or any Installomator recipe. Without Title Editor, there is no Jamf-integrated path to compliance visibility or automated enforcement.

#### Creating the Software Title

```bash
source ~/title_editor/title_editor_api_ctrl.sh
bash ~/title_editor/title_editor_menu.sh \
  --create-title \
  --title-name "Palo Alto GlobalProtect" \
  --new-title-id globalprotect \
  --publisher "Palo Alto Networks" \
  --bundle-id com.paloaltonetworks.globalprotect \
  --version 6.2.4 \
  --yes
```

#### Back-Populating Version History

Palo Alto Networks maintains public release notes for GlobalProtect. The release-notes batch builder parses this page to create a full version history in Title Editor:

```bash
bash ~/title_editor/build_title_editor_batch_from_release_notes.sh \
  --url "https://docs.paloaltonetworks.com/globalprotect/6-2/globalprotect-release-notes" \
  --title-name "Palo Alto GlobalProtect" \
  --output ~/title_editor/batches/globalprotect.txt

# Review the generated file, then import:
source ~/title_editor/title_editor_api_ctrl.sh
bash ~/title_editor/title_editor_menu.sh \
  --add-patch-batch \
  --file ~/title_editor/batches/globalprotect.txt
```

#### Adding Each New Release

1. Download the new installer PKG from the Palo Alto Networks support portal.
2. Test the installer in an isolated lab environment.
3. Add the new version record to Title Editor:

```bash
source ~/title_editor/title_editor_api_ctrl.sh
bash ~/title_editor/title_editor_menu.sh \
  --add-patch \
  --title-name "Palo Alto GlobalProtect" \
  --version 6.2.5 \
  --yes
```

4. Upload the tested PKG to Jamf Pro and attach it to the new version in the Patch Management software title.
5. On the next patch feed refresh, Jamf Pro detects the new version. The compliance dashboard updates and the Patch Policy begins delivering the upgrade to out-of-date machines.

#### Scope and Distribution Controls

Because GlobalProtect is a campus-licensed application, its Jamf Pro Patch Policy is scoped to a smart group containing only machines expected to have it installed — for example, `All Managed Laptops` or a VPN-entitled machines group. This prevents correctly unscoped machines from appearing as non-compliant on the dashboard.

> **Distribution note:** GlobalProtect is delivered to all eligible machines via a mandatory Jamf Pro Policy (not Self Service, since it is required infrastructure). The Title Editor-backed Patch Policy enforces version currency on top of that, without redistributing the full installer every time.

---

## Mac App Store Applications — Repackaging and Post-Install Automation

### Why Jamf Pro's Native Mac App Store Deployment Is Not Enough for Some Applications

Jamf Pro streamlines Mac App Store app deployment using Volume Purchase Program (VPP) licenses, allowing automatic, silent installation and management of both free and paid apps without requiring an Apple ID on the device. Jamf Pro can scope any VPP-licensed App Store application to a group of computers and trigger a silent install using Apple's MDM framework. For straightforward applications used in a standard context, this works well.

However, Jamf Pro's MDM-based Mac App Store deployment process does not currently support post-installation workflows such as running scripts after an app is installed or upgraded. Apple's MDM framework controls the installation entirely — Jamf Pro sends the install command, the operating system contacts Apple's servers and downloads the app, and the app lands in `/Applications`. There is no hook for the IT team to run code before or after that process.

For many applications this is acceptable. For professional creative and developer tools — particularly in a multi-user lab environment managing thousands of endpoints — it creates a hard operational problem:

- **Xcode** requires accepting the Xcode and Apple SDKs license agreement non-interactively before its toolchain is usable, and requires `xcode-select` to be pointed at the correct developer directory. Without these post-install steps, Xcode presents an admin-credential license dialog on first launch for every user on every machine. At lab scale, this is unmanageable.
- **Final Cut Pro** benefits from pre-staged shared project library locations, pre-installed Pro Video Formats, and organizational preference seeding — none of which can be scripted through MDM app assignment.
- **Logic Pro** has a multi-gigabyte Sound Library. Without a post-install script pointing all users at a shared library path, every user on a shared Mac independently triggers a large download on first launch, consuming significant storage and bandwidth across the fleet.
- **GarageBand** has the same shared Sound Library problem in lab environments, and benefits from organizational loop library pre-staging.

Additionally, **Jamf Pro App Installers does not cover paid Mac App Store titles.** Final Cut Pro, Logic Pro, and the full Xcode IDE are not in the App Installers catalog. The only Jamf-native path to deploying these without repackaging is the MDM VPP assignment mechanism — which provides no post-install scripting capability.

> **The core limitation:** For applications that require post-install configuration to function correctly in a managed, multi-user environment at scale, the MDM delivery mechanism alone is insufficient. Repackaging as a standard PKG and deploying through a Jamf Pro Policy is the solution.

---

### The Repackaging Solution

The Marriott Library IT approach is to obtain Mac App Store applications through ABM volume licensing, download them on an authorized management Mac, and repackage them as standard flat PKG installers using Jamf Composer, `pkgbuild`/`productbuild`, or `munkipkg`. This converts the App Store application into a standard managed package that Jamf Pro can deploy through a regular Policy — with full support for pre-install and post-install scripts.

This approach provides:

- **Full post-install scripting** — license acceptance, developer directory configuration, shared library path setup, preference seeding, and any other configuration the application requires.
- **Deterministic deployment** — a PKG deployed via a Jamf Pro Policy behaves identically on every machine, at the same time, regardless of App Store connectivity, MDM user state, or user interaction.
- **Patch Management integration via Title Editor** — a standard PKG attaches to a Patch Policy version record, providing the compliance dashboard and enforced upgrade capability that MDM app assignment does not offer.
- **Version control** — the IT team controls exactly which version is deployed and when, independent of App Store automatic update behavior.

> **Distribution rights:** Repackaging and internal redistribution must comply with App Store terms and the institution's ABM/VPP agreement. Xcode is freely redistributable under the Xcode and Apple SDKs License Agreement. Final Cut Pro, Logic Pro, and GarageBand are licensed per ABM seat and should only be deployed to machines with valid volume assignments.

---

### General Repackaging and Deployment Workflow

1. On an authorized Mac enrolled in ABM, download the application from the Mac App Store using the ABM-assigned volume license.
2. Build a flat PKG using Jamf Composer, `pkgbuild`/`productbuild`, or `munkipkg`. The PKG installs the `.app` bundle, any pre-staged support files, and runs a post-install script.
3. Sign the PKG with a Developer ID Installer certificate.
4. Test in an isolated lab environment — verify the post-install script runs correctly and the application opens without prompting for manual setup.
5. Upload the PKG to Jamf Pro.
6. Create or update the Title Editor software title using the `--mac-app-store` batch builder (for initial version history) or `--add-patch` (for new releases).
7. In Jamf Pro Patch Management, attach the PKG to the appropriate version record. The compliance dashboard immediately shows installed vs. current versions across the fleet.
8. The Patch Policy distributes the new version to scoped machines with IT-configured deadlines, deferrals, and user notifications.

---

### Final Cut Pro

Final Cut Pro is the primary video editing application in the Marriott Library's Digital Scholarship Lab and media production facilities. It is a paid MAS title licensed through ABM/VPP and not available via Jamf Pro App Installers.

#### Why Post-Install Scripting Is Required

In a multi-user lab environment, Final Cut Pro's default first-run behavior creates friction that scales poorly across thousands of machines:

- Each user who opens Final Cut Pro for the first time is prompted to choose a library location. In a lab context this is confusing and leads to project files scattered across per-user home directories.
- **Pro Video Formats** — a separate Apple package required for H.264 hardware acceleration, ProRes RAW, HEVC, and many professional camera codecs — is not bundled with Final Cut Pro and is not installed automatically via MDM assignment. Without it, users may encounter codec errors or be prompted to download the package themselves on first use.

#### Post-Install Configuration

- Create a shared project templates directory (e.g. `/Users/Shared/FinalCutPro`) for multi-user lab workflows.
- Pre-stage the Pro Video Formats package to ensure camera format compatibility on first launch without prompting the user for an additional download.
- Seed organizational default preferences via a managed Configuration Profile or `defaults write` commands in the post-install script.

#### Title Editor Version Tracking

```bash
bash ~/title_editor/build_title_editor_batch_from_release_notes.sh \
  --mac-app-store \
  --mac-app-store-name "Final Cut Pro" \
  --title-name "Final Cut Pro" \
  --output ~/title_editor/batches/finalcutpro.txt

source ~/title_editor/title_editor_api_ctrl.sh
bash ~/title_editor/title_editor_menu.sh \
  --add-patch-batch \
  --file ~/title_editor/batches/finalcutpro.txt
```

---

### Logic Pro

Logic Pro is Apple's professional digital audio workstation, installed in the Marriott Library's audio recording suites and music technology workstations. It is a paid MAS title licensed through ABM/VPP.

#### Why Post-Install Scripting Is Required

Logic Pro's Sound Library is a multi-gigabyte collection of samples, loops, and instruments. By default, each user account downloads its own copy to `~/Music/Audio Music Apps/`. On a shared lab Mac with many student users, every new user triggers a large download on first launch — multiplied across hundreds of machines, this represents significant storage overhead and network load.

#### Post-Install Configuration

- Configure a shared Sound Library path (`/Users/Shared/LogicProSoundLibrary`) so all users on a machine share downloaded sample content rather than each independently downloading gigabytes.
- Seed organizational workspace preferences (project templates, I/O configurations) via `defaults write` targeting `com.apple.logic10` in the post-install script.
- Distribute additional Logic Pro content packages through a separate Jamf Pro Policy targeting a managed content directory, keeping the primary PKG a manageable size.

#### Title Editor Version Tracking

```bash
bash ~/title_editor/build_title_editor_batch_from_release_notes.sh \
  --mac-app-store \
  --mac-app-store-name "Logic Pro" \
  --title-name "Logic Pro" \
  --output ~/title_editor/batches/logicpro.txt

source ~/title_editor/title_editor_api_ctrl.sh
bash ~/title_editor/title_editor_menu.sh \
  --add-patch-batch \
  --file ~/title_editor/batches/logicpro.txt
```

---

### GarageBand

GarageBand is Apple's consumer digital audio workstation, available as a free MAS title and installed on general-purpose student Macs and music classroom machines at the Marriott Library.

#### Why Post-Install Scripting Is Useful

GarageBand is free and can be deployed via MDM assignment for simple use cases. However, in a shared lab environment the same Sound Library problem applies as with Logic Pro — by default every user independently downloads the loop and sample library on first launch. In a fleet of thousands of machines, this creates unnecessary storage and bandwidth consumption that a post-install script eliminates.

#### Post-Install Configuration

- Point GarageBand's Sound Library to a shared path (`/Users/Shared/GarageBandSoundLibrary`) via `defaults write` targeting `com.apple.garageband10`.
- Pre-download essential loop content to the shared library during PKG deployment, using the command-line interface Apple provides in GarageBand's bundle.

#### Title Editor Version Tracking

```bash
bash ~/title_editor/build_title_editor_batch_from_release_notes.sh \
  --mac-app-store \
  --mac-app-store-name "GarageBand" \
  --title-name "GarageBand" \
  --output ~/title_editor/batches/garageband.txt

source ~/title_editor/title_editor_api_ctrl.sh
bash ~/title_editor/title_editor_menu.sh \
  --add-patch-batch \
  --file ~/title_editor/batches/garageband.txt
```

---

## Quick Reference



### Common Commands

| Task | Command |
|---|---|
| Store credentials | `bash setup_title_editor_credentials.sh` |
| Verify credentials | `bash setup_title_editor_credentials.sh --verify` |
| Interactive menu | `source title_editor_api_ctrl.sh && bash title_editor_menu.sh` |
| Create a new title | `bash title_editor_menu.sh --create-title --title-name "App" --bundle-id com.app --version 1.0 --yes` |
| Add single patch version | `bash title_editor_menu.sh --add-patch --title-name "App" --version "1.2.3" --yes` |
| Batch import | `bash title_editor_menu.sh --add-patch-batch --file batch.txt` |
| Dry-run a batch | `bash title_editor_menu.sh --add-patch-batch --file batch.txt --dry-run` |
| Build batch from GitHub | `bash build_title_editor_batch_from_github.sh --repo owner/repo --title-name "App" --output out.txt` |
| Build batch from Jamf Patch catalog | `bash build_title_editor_batch_from_jamf_patch_catalog.sh --source jamf-pro --software-name "App (Jamf)" --title-name "App" --output out.txt` |
| Build batch from release notes | `bash build_title_editor_batch_from_release_notes.sh --url https://... --title-name "App" --output out.txt` |
| Build batch from Mac App Store | `bash build_title_editor_batch_from_release_notes.sh --mac-app-store --mac-app-store-name "Xcode" --title-name "Xcode" --output out.txt` |
| Prompt software title defaults | `bash title_editor_software_title_defaults_from_user_prompt.sh` |
| Run orchestrated version update | `bash update_title_editor_versions.sh --item <key> --current-only --no-import --no-apply` |
| Export title to JSON | `bash title_editor_menu.sh --export-title-json --title-name "App" --output title.json` |
| Resequence patches | `bash title_editor_menu.sh --resequence-only --title-name "App" --yes` |

---

### Environment Variables

| Variable | Purpose |
|---|---|
| `GH_TOKEN` | GitHub personal access token — raises API rate limit from 60 to 5,000 requests/hour. |
| `TITLE_EDITOR_API_PW` | Title Editor API password for non-Keychain use (e.g. CI/CD pipelines). |
| `TITLE_EDITOR_MENU_DEBUG` | Set to `true` for safe credential debug output (fingerprints only, never plaintext). |
| `TEM_API_GUARD_TIMEOUT` | Per-API-call timeout in seconds (default 75). Prevents batch hangs on slow servers. |
| `TEM_RECONNECT_TIMEOUT` | Timeout for token-refresh reconnect attempts (default 20s). |
| `TEM_TITLE_UPDATE_TIMEOUT` | Timeout for the `currentVersion` PATCH call after patch creation (default 20s). |
| `TEM_AUTO_RESEQUENCE_ON_CHANGE` | Set to `false` to disable automatic patch resequencing after batch operations. |