# Bambu Nextcloud Sync — GitHub Copilot Engineering Handoff

**Status:** Requirements approved; implementation not yet started  
**Specification date:** 2026-11-26  
**Suggested repository/image name:** `bambu-nextcloud-sync`  
**Primary language for documentation:** English  
**Intended audience:** GitHub Copilot coding agent and project maintainers

> **Agent instruction:** Treat this document as the functional specification. Design and implement a complete, secure, documented, testable open-source Docker service. The confirmed device observations below are facts from the user's FileZilla test; do not reinterpret them as unverified assumptions. Do not claim tests, builds, or live connections succeeded unless you actually execute them. Start with a plan and implement the P0 milestones incrementally.

## 1. Project objective

Build a standalone, reusable Docker service that periodically retrieves Bambu Lab 3D-print project files (`.3mf`) from a printer's local FTPS storage and synchronizes them to a user's Nextcloud folder via WebDAV.

- The service is **one-way: Bambu printer → Nextcloud**.
- The source printer must always remain **read-only**: never delete, move, rename, or modify files on the printer.
- All behavior choices listed below must be configurable via environment variables, with safe defaults.
- Release as an open-source GitHub repository and a simple-to-run Docker image for Docker Hub, optionally also GHCR.
- The service must survive disconnections, container restarts, partial transfers, and repeated scans without corrupting files or producing accidental duplicate versions.

### Operating context

- The initial device is a **Bambu Lab P2S**, with a USB stick installed.
- The user operates Docker on an Ubuntu VM hosted under Proxmox on an HP Z420; their Nextcloud server runs in Docker in that environment.
- The application should not depend on Proxmox, Home Assistant, the specific Nextcloud deployment, or this hardware.
- No need for a dashboard or Home Assistant integration in v1.

## 2. Confirmed device facts

**Verified manually using FileZilla on Windows:**

- Printer's local storage is accessible using **implicit FTPS on TCP port 990**.
- FTP username: `bblp`.
- Password: the printer's **local LAN access code** (not the Bambu cloud account password).
- Downloading files succeeds.
- FTP root `/` contains multiple `*.3mf` files and a `timelapse/` directory.
- `/timelapse/` contains finished MP4 recordings, a `thumbnail/` directory and `tmp.video` while a print is underway.
- `timelapse/thumbnail/` has preview JPGs named like the MP4 stem (including `_mini.jpg` variants).

Example only:

```text
/
├── project_1.3mf
├── project_2.3mf
└── timelapse/
    ├── video_2026-11-21_20-58-28.mp4
    ├── tmp.video
    └── thumbnail/
        ├── video_2026-11-21_20-58-28.jpg
        └── video_2026-11-21_20-58-28_mini.jpg
```

**Important:** This project's default scope is only `.3mf` files in the root directory, **not** time-lapse MP4s, thumbnails, `.gcode`, or files still being written. Recursive scanning is optional and should still match only `.3mf` files.

## 3. Technical approach

### Preferred stack

- **rclone** is the primary transfer engine; prefer a minimal container based on the official `rclone/rclone` image, subject to checking the available base-image shell/tools and multi-architecture compatibility.
- Use a small, maintainable shell orchestration layer (POSIX shell / BusyBox `sh` where feasible). Add a small helper (for example Python or Go) **only if justified** for reliable structured state management, checksums, 3MF metadata parsing or safe filesystem operations. Avoid introducing Node.js merely to reimplement FTPS/WebDAV.
- Source backend: rclone **FTP backend with implicit TLS**, port `990`, TLS enabled; do **not** configure explicit TLS by mistake.
- Destination backend: rclone **WebDAV backend**, provider/vendor `nextcloud`, authenticated with a Nextcloud username and a dedicated **app password**.
- Suggested Nextcloud WebDAV endpoint format: `https://cloud.example.com/remote.php/dav/files/USERNAME/` (respect installations in a URL subpath). Do not confuse this with the Nextcloud browser UI URL.
- Prefer an **FTPS → local staging → Nextcloud WebDAV** pipeline rather than a direct remote-to-remote copy when it makes safe write-stability detection, local hashing, metadata extraction, and retries more dependable.
- Durable writable volume at `/data` for synchronization state and download staging.
- No external database required for v1; use SQLite if available/justified, otherwise an atomic, validated JSON manifest with adequate locking. Never depend only on ephemeral container storage.

### High-level flow

1. Validate configuration, connectivity and target folder safety.
2. Obtain a complete source listing, filtered according to `SCAN_MODE`.
3. Distinguish a valid empty listing from a failure, but **never interpret unexpected emptiness as permission to delete**.
4. Wait until files are stable: compare remote size (and modification time where reliable) across at least two checks, separated by a configurable stability interval. Do not infer completion simply from the `.3mf` extension.
5. Download each eligible file into a temporary staging path, never directly into its final destination. Confirm successful transfer, recheck remote size, and compute local SHA-256. If source changes during transfer, discard/retry.
6. Determine conflict behavior and whether upload is needed. No needless overwrite of an unchanged file.
7. Upload via rclone WebDAV. If upload fails, retain/retry the staging file; never mark the item as complete prematurely.
8. Confirm destination presence and reasonable integrity (size and hash if both backend and operations support the same hash; otherwise document weaker verification).
9. Atomically persist the successful source-to-destination mapping and content fingerprint, then safely clean staging.
10. Only after a fully successful, validated source scan and upload phase, optionally plan/apply destination deletions for a configured mirror mode, subject to safety gates.
11. Emit useful structured logs and clear exit/health status.

Avoid concurrent runs against the same state/destination. Acquire a single-instance lock; remove stale locks safely.

## 4. User-facing configuration contract

All choices are **end-user configuration**, not build-time assumptions. Preserve these settings and defaults unless a demonstrated technical limitation requires a documented change.

| Environment variable | Values / description | Default |
| --- | --- | --- |
| `BAMBU_HOST` | Printer hostname/IP; required | none |
| `BAMBU_PORT` | Implicit FTPS port | `990` |
| `BAMBU_USERNAME` | FTP username | `bblp` |
| `BAMBU_ACCESS_CODE` | Local printer access code; required; secret | none |
| `BAMBU_SOURCE_PATH` | Printer source directory | `/` |
| `NEXTCLOUD_WEBDAV_URL` | Full WebDAV base URL pointing at user files; required | none |
| `NEXTCLOUD_USERNAME` | Nextcloud account; required | none |
| `NEXTCLOUD_APP_PASSWORD` | Nextcloud app password; required; secret | none |
| `NEXTCLOUD_FOLDER` | Folder relative to that user's WebDAV root | `3D Druck/Bambu P2S/Projekte` |
| `SCAN_MODE` | `root` / `recursive` | `root` |
| `SYNC_MODE` | `archive` / `mirror` | `archive` |
| `MIRROR_MODE` | `managed` / `exact`, used only when `SYNC_MODE=mirror` | `managed` |
| `CONFLICT_MODE` | `version` / `overwrite` / `skip` | `version` |
| `EXTRACT_METADATA` | `true` / `false` | `false` |
| `SYNC_INTERVAL` | Seconds between sync runs; must be positive | `300` |
| `STABILITY_CHECK_INTERVAL` | Seconds between source stability samples; configurable | `30` (proposed) |
| `DRY_RUN` | Report proposed writes/deletions without changing source or destination | `false` |
| `LOG_LEVEL` | `error`, `warn`, `info`, `debug` | `info` |
| `TZ` | Container timezone for logs | `UTC` |
| `MAX_DELETE_COUNT` | Maximum deletions permitted per run; additional protection | `10` (proposed) |
| `MAX_DELETE_PERCENT` | Maximum percentage of tracked/eligible target files deleted per run | `20` (proposed) |
| `ALLOW_EMPTY_SOURCE_MIRROR` | **Must default to false**; dangerous override, never enough to bypass connectivity checks | `false` |

Document any additional options clearly; optional TLS trust/CA configuration is preferable to globally disabling verification. `DELETE_SOURCE` is **not a feature**: deletion on the printer is prohibited by design.

### Selection semantics

- `SCAN_MODE=root`: synchronize `.3mf` files directly under `BAMBU_SOURCE_PATH`, without traversing subdirectories.
- `SCAN_MODE=recursive`: recursively synchronize `.3mf` files under that source path; **preserve relative subfolder structure** in Nextcloud. Explicitly ignore MP4/JPG/temp files.
- Paths are case-safe and Unicode-safe; use robust quoting/escaping for spaces, accents, punctuation, and non-ASCII names.
- Do not allow unsafe paths (`..`, blank target directory, WebDAV account root as an accidental target). Prevent targets escaping the configured Nextcloud folder.
- Validate the source/destination are not accidentally pointing at the same physical storage or a recursively nested location.

### Synchronization modes

**`SYNC_MODE=archive` (safe default)**
- Upload new/modified source files according to conflict policy.
- Never delete Nextcloud files if they disappear from the printer.
- All mode combinations should be explicitly tested.

**`SYNC_MODE=mirror`**
- Upload new/modified files as above, then consider deletion of files absent from the source only after strict safety checks.
- Never delete from printer.
- Do not blindly invoke `rclone sync` without applying the app's deletion policy; a custom deletion planner may be required.

**`MIRROR_MODE=managed` (default mirror policy)**
- Only files with durable proof that this service successfully uploaded/managed them may be removed when no longer in the confirmed source inventory.
- Other manually added Nextcloud files **must be preserved**.
- If state is lost, invalid, corrupted, or newly initialized: do not retrospectively classify destination files as managed; do not delete them.
- A missing source file is not enough: require a successful complete source scan and applicable safeguards.

**`MIRROR_MODE=exact` (explicitly destructive)**
- Treat the configured Nextcloud folder as a managed mirror of the in-scope `.3mf` source set.
- Files absent from that set, including user-added files within the designated mirror scope, **may** be deleted; disclose this prominently in README.
- Scope is the exact configured project destination subtree, never the user's full Nextcloud account.
- Define what happens to unrelated extensions and metadata artifacts carefully: exact mode is an exact mirror of the selected 3MF project set, and must not unexpectedly wipe service-generated metadata. Document exclusions, and make the destructive scope explicit.
- Require an initial baseline/inventory and safe test plan; no mass deletions on first run by default. Consider requiring a dedicated opt-in like `ALLOW_EXACT_MIRROR=true` in addition to `SYNC_MODE=mirror` and `MIRROR_MODE=exact`.

### Conflict modes and Nextcloud versioning

**`CONFLICT_MODE=version` (default; user's selected versioning strategy)**
- The destination path stays the **same** for the same project filename; do **not** create timestamp-suffixed version files.
- When source content has changed, update the destination through Nextcloud WebDAV in a manner compatible with Nextcloud's `files_versions` app.
- Ensure or explicitly verify `files_versions` is enabled before claiming the old version is retained. Depending on permissions, this might require a documented admin-side check rather than an API-only check. On unknown status, issue a prominent warning and provide a fail-safe behavior (recommend fail closed before a potentially destructive overwrite in strict `version` mode).
- Understand that Nextcloud version history is governed by server-side retention and quota policy; **do not promise permanent retention**.
- Avoid repeated unchanged uploads (which would create unnecessary versions).

**`CONFLICT_MODE=overwrite`**
- Reuse the same destination filename and update changed content without requiring Nextcloud versioning. Nextcloud may still retain older versions if its app is enabled; the client must not claim to disable server-side versions.

**`CONFLICT_MODE=skip`**
- Once the destination filename already exists, do not overwrite it, even if source content differs; log this unambiguously. The service should still handle new filenames normally.

**Critical distinction:** `version` and `overwrite` can use a similar WebDAV `PUT` at the transport layer. Their *product-level* difference is mandatory Nextcloud versioning validation/guarding for `version` versus no such requirement for `overwrite`. Do not implement fictitious Nextcloud version guarantees.

## 5. Mandatory safety requirements

1. **Never modify the printer**, including in mirror mode.
2. **Never delete Nextcloud content following a failed, incomplete, or unexpectedly empty source listing.** Distinguish a successful empty listing from error, but still require an explicit guard for the empty case.
3. Apply `MAX_DELETE_COUNT`, `MAX_DELETE_PERCENT`, bounded target paths, and preferably a two-phase deletion plan with an auditable list of exact affected files.
4. No deletion during a run with unresolved staging/download/upload errors or failed destination inventory checks.
5. Respect `DRY_RUN` for *all* destination mutations, including folder creation, overwrite, versions and deletion. Source listing is permitted; downloading to ephemeral scratch for inspection should be documented if performed, but favor dry-run without data-transfer side effects.
6. Use a **full source inventory** for mirror decisions, not a partial `rclone lsf` output or a timer-based assumption.
7. Prevent path traversal, command injection, accidental shell word splitting, CRLF filename confusion, and log injection. Validate configuration before launching rclone.
8. Protect secrets: `.env` not committed, secret redaction in logs, no secrets in CLI process arguments if avoidable, limit file permissions. Prefer rclone config via protected temporary config file or environment variables, and describe the tradeoff.
9. TLS verification must default to enabled for Nextcloud; support CA bundle customization. Bambu may have a self-signed certificate; provide a printer-specific trust mechanism or clearly scoped opt-in for insecure printer TLS, **never** globally disable Nextcloud TLS validation as a shortcut.
10. If preserving a version is requested but Nextcloud versioning is not verified, do not silently overwrite as if retention were guaranteed.
11. Upload completion and state persistence must be ordered correctly. Protect against crashes between upload and checkpoint; on restart reconcile the remote target instead of blindly re-uploading changed content.
12. No secret values, passwords, LAN access codes, tokens, or test credentials in GitHub logs or public artifacts.

## 6. Metadata extraction (`EXTRACT_METADATA=true`)

3MF packages are ZIP-based containers, but the exact metadata/thumbnail contents vary by producer and file. Implement this as an **optional enhancement**, never a prerequisite for 3MF transfer.

- Parse only after a complete verified local download.
- Extract available thumbnails and lightweight project metadata; gracefully handle absent/unexpected schemas.
- Implement defenses against zip-slip/path traversal, zip bombs, oversized archive entries, malformed XML and excessive memory consumption.
- Define an unobtrusive, deterministic output layout (for example a reserved per-project `.metadata` subtree) with stable naming and separately documented retention/overwrite rules.
- Ensure mirror-exact semantics do not accidentally delete generated metadata or unrelated user files in a surprising manner. Tests must cover the interaction.
- `EXTRACT_METADATA=false` must add no metadata files to Nextcloud.

## 7. Reliability, state, and observability

Suggested state fields per managed item:

```json
{
  "schema_version": 1,
  "source_path": "example.3mf",
  "destination_path": "3D Druck/Bambu P2S/Projekte/example.3mf",
  "source_size": 123456,
  "source_modified_at": null,
  "sha256": "<actual locally computed SHA-256>",
  "last_uploaded_at": "<UTC ISO8601>",
  "confirmed_destination_size": 123456,
  "managed_by_service": true
}
```

- The above is a **schema example**, not a real manifest. Don't hardcode example hashes.
- Atomic persistence using write-then-rename (or transactions) with validation/recovery.
- State volume should remain usable across image rebuilds and updates; define a schema migration strategy.
- Perform a startup rescan and reconciliation before any deletion.
- Use per-file retries with capped exponential backoff; transient printer/network failures are expected.
- Produce human-readable log lines for scanned, stable, downloaded, uploaded, skipped, version-updated, deleted, errors, and scan summary.
- Add Docker `HEALTHCHECK` only if it accurately reports process health (not merely container running). Document health semantics. Avoid marking a healthy intermittent offline printer as a permanent fatal error unless configured.
- A failed synchronization attempt should be visible in logs/health while allowing recovery.
- Use bounded staging disk usage and configurable concurrency; don't download thousands of files unboundedly.

## 8. Proposed repository structure

```text
bambu-nextcloud-sync/
├── .github/
│   ├── workflows/
│   │   ├── ci.yml
│   │   ├── docker-publish.yml
│   │   └── base-image-rebuild.yml
│   └── dependabot.yml
├── src/
│   ├── entrypoint.sh
│   ├── config.sh
│   ├── discover.sh
│   ├── transfer.sh
│   ├── mirror.sh
│   └── state.*                # choose one justified implementation
├── tests/
│   ├── fixtures/
│   ├── unit/
│   └── integration/
├── Dockerfile
├── compose.yaml
├── .env.example
├── .dockerignore
├── .gitignore
├── LICENSE
├── README.md
├── SECURITY.md
├── CHANGELOG.md
└── COPILOT_HANDOFF.md        # this document, optional rename
```

Structure is guidance, not a demand for empty placeholder files. Favor coherent, minimal modules rather than splitting trivial logic unnecessarily.

## 9. Docker Compose UX (target shape; illustrative, not yet runnable)

```yaml
services:
  bambu-nextcloud-sync:
    image: YOUR_DOCKERHUB_USER/bambu-nextcloud-sync:latest
    restart: unless-stopped
    init: true
    env_file: .env
    volumes:
      - ./data:/data
    security_opt:
      - no-new-privileges:true
    stop_grace_period: 30s
```

`.env.example` should contain all required connection variables plus documented optional values, but **no real secrets**.

Example configuration:

```dotenv
BAMBU_HOST=192.168.1.50
BAMBU_PORT=990
BAMBU_USERNAME=bblp
BAMBU_ACCESS_CODE=REPLACE_ME
BAMBU_SOURCE_PATH=/
NEXTCLOUD_WEBDAV_URL=https://nextcloud.example.com/remote.php/dav/files/USERNAME/
NEXTCLOUD_USERNAME=USERNAME
NEXTCLOUD_APP_PASSWORD=REPLACE_ME
NEXTCLOUD_FOLDER=3D Druck/Bambu P2S/Projekte
SCAN_MODE=root
SYNC_MODE=archive
MIRROR_MODE=managed
CONFLICT_MODE=version
EXTRACT_METADATA=false
SYNC_INTERVAL=300
DRY_RUN=false
MAX_DELETE_COUNT=10
MAX_DELETE_PERCENT=20
TZ=Europe/Berlin
```

Don't ship a real public image name before publishing it. Choose a user/project-owned registry namespace during release setup.

## 10. Test strategy and acceptance criteria

### P0 — Core functionality

- [ ] Container builds locally on a chosen supported architecture; validate the official rclone base compatibility.
- [ ] `docker compose config` passes using example environment values.
- [ ] Connect to mock or real FTPS using implicit TLS port 990; list root and download `.3mf` without modifying source.
- [ ] Connect to a Nextcloud WebDAV test server using app password; create target folder and upload a `.3mf`.
- [ ] Default root scanning excludes nested `.3mf`; recursive scanning includes nested `.3mf` with preserved structure.
- [ ] Files in progress are not uploaded until stable and complete.
- [ ] Restart-safe deduplication; repeated unchanged scans do not create extra uploads/versions.
- [ ] Archive mode never deletes destination files.
- [ ] `DRY_RUN` performs no destination changes.
- [ ] No credentials in logs.

### P1 — Conflict and mirror modes

- [ ] `version` checks/prerequisites documented and enforced; update reuses same filename; Nextcloud version history behavior tested against a real instance with `files_versions` enabled.
- [ ] `overwrite` updates without promising historical retention.
- [ ] `skip` does not alter an existing target path.
- [ ] Managed mirror only deletes files with positive prior management records.
- [ ] Exact mirror can delete extra user files **inside clearly documented deletion scope**, never outside it.
- [ ] Mirror deletion blocked on listing/transfer failure, empty source, missing or inconsistent state, threshold exceeded, and first-run safety conditions.
- [ ] After state loss, no unintended managed deletions.
- [ ] All mode combinations have explicit regression tests.

### P2 — Metadata and quality

- [ ] Optional thumbnail/metadata extraction, safe against malformed archives and missing data.
- [ ] No metadata when option disabled.
- [ ] Useful logs and optional proper health reporting.
- [ ] CI unit tests and mocked FTPS/WebDAV integration tests.
- [ ] Automated dependency scans and documented secure configuration.

### P3 — Open-source distribution

- [ ] README: quickstart, full configuration reference, examples, supported models and known limitations.
- [ ] SECURITY.md, LICENSE (maintainer to choose, e.g. MIT or Apache-2.0), contribution notes.
- [ ] GitHub Actions to run tests and publish tagged/multiarch images to Docker Hub and optionally GHCR.
- [ ] Periodically rebuild on newer upstream rclone base images, **run tests and publish only if passing**.
- [ ] Never assume the `latest` base tag automatically updates previously published images.
- [ ] Use immutable image tags/digests for reproducibility and provide release notes.
- [ ] At least one full dry-run and real-sync walkthrough with a test Nextcloud folder before enabling destructive modes.

## 11. Priority safety matrix

| Scenario | Required behavior |
| --- | --- |
| Printer unreachable | Retry later; never delete target files |
| Source returns an error or only a partial listing | Abort destructive phase |
| Source unexpectedly has zero matching 3MF | No deletion by default |
| Active or changing 3MF | Wait; no upload until stable |
| Power loss during staging | Resume/re-download safely; no partial final upload |
| Upload succeeds but checkpoint fails | Reconcile destination, avoid duplicate version |
| Missing/corrupt state | Recover conservatively; no managed deletions |
| `mirror + managed` with manually added target file | Preserve manually added file |
| `mirror + exact` with manually added target file | Eligible for deletion *only* within explicit scope, after all safeguards |
| `version` mode, version app absent/unknown | Warn or refuse changed-file overwrite; do not claim version retention |
| Target is WebDAV account root | Reject unsafe configuration |
| `DRY_RUN=true` | No mutations in Nextcloud or printer |

## 12. Known subtleties and implementation guidance

1. rclone FTP may provide limited or unreliable modification times and no compatible server hashes. A size/mtime-only comparison is not a proof of byte identity; staged SHA-256 and cautious reconciliation are important.
2. rclone's ordinary `copy` updates same-name files unless configured otherwise. The app must implement conflict semantics deliberately.
3. rclone `sync` can delete target files. Managed deletion should be implemented as a controlled manifest-based planner, **not** an unrestricted `sync` command.
4. `--max-delete` by itself is not a complete safeguard: apply additional scope, first-run, source-health and percentage protections. See rclone's official docs.
5. Nextcloud's WebDAV `PUT` overwrites a path, while the Nextcloud Versions app controls historical snapshots and expiry. The service cannot promise immortal versions or unilaterally force the server's retention policy.
6. The Nextcloud user must have write permissions in the destination folder. Use an app password, not a primary account password.
7. FTPS certificates on local printers may be self-signed. Give operators secure and clearly documented options to trust the printer, not a blanket insecure mode for all remotes.
8. FTP filename behavior, Unicode, quoting and time zone conversion can differ; test filenames with spaces and non-ASCII characters.
9. Run exactly one stateful synchronizer instance per configured printer/Nextcloud destination unless safe coordination is explicitly implemented.
10. Scope discovery to known verified Bambu P2S behavior. Support for other Bambu models is a goal, **not** an unverified compatibility claim.

## 13. Reference documentation (verify syntax against installed rclone version)

- rclone FTP backend: https://rclone.org/ftp/
- rclone WebDAV/Nextcloud: https://rclone.org/webdav/
- rclone copy: https://rclone.org/commands/rclone_copy/
- rclone sync and deletion behavior: https://rclone.org/commands/rclone_sync/
- rclone general filtering/flags: https://rclone.org/filtering/
- Nextcloud WebDAV user documentation: https://docs.nextcloud.com/server/stable/user_manual/en/files/access_webdav.html
- Nextcloud WebDAV developer documentation: https://docs.nextcloud.com/server/stable/developer_manual/client_apis/WebDAV/basic.html
- Nextcloud file versioning/aging: https://docs.nextcloud.com/server/stable/admin_manual/configuration_files/file_versioning.html

## 14. Recommended first task for Copilot

> Read this entire handoff. Start by proposing a small implementation plan and documenting any technical uncertainty discovered in the actual current rclone/Nextcloud APIs. Build a minimal, working FTPS → Nextcloud WebDAV sync with persistent state, `SCAN_MODE`, archive mode, stable-file checks, `DRY_RUN`, and Docker Compose. Write tests before implementing deletion. Then add each conflict and mirror mode with comprehensive safety tests. Do not mark functionality as implemented until it passes tests; do not enable `mirror + exact` in a real environment by default. Keep the project ready for Docker Hub/GitHub publication.

---

**Approval scope:** Product requirements are approved. Implementation, tests, live Nextcloud validation, public repository creation, and container publication remain to be performed.
