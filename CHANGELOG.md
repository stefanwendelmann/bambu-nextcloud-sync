# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

- One-way sync of `.3mf` files from a Bambu Lab printer (implicit FTPS) to a Nextcloud folder (WebDAV), based on rclone.
- `SCAN_MODE` `root` and `recursive`.
- Stability check with two source listings before a file is transferred.
- Staged downloads with SHA-256 verification, upload verification, and an atomically written state manifest.
- `CONFLICT_MODE` `version` (guarded by the Nextcloud Versions app), `overwrite` and `skip`.
- `DRY_RUN`, `RUN_ONCE` and `--check-config`.
- Unit tests and end-to-end tests against a printer stand-in and a real Nextcloud server.

### Not implemented

- `SYNC_MODE=mirror` (deletions in Nextcloud) and `EXTRACT_METADATA=true`. The service refuses to start with either.
