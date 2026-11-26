# Bambu Nextcloud Sync

Copies the `.3mf` project files from a Bambu Lab printer into a folder of your Nextcloud, automatically and in one direction only: **printer → Nextcloud**.

The container connects to the printer's local storage (implicit FTPS, port 990), waits until a file is completely written, downloads it, and uploads it to Nextcloud through WebDAV using [rclone](https://rclone.org/). The printer is only ever listed and read. Nothing on it is changed, moved or deleted.

> **Status:** early release. Every change is tested automatically against a stand-in for the printer and a real Nextcloud server (see [Validation status](#validation-status)). A run against a physical printer has not been recorded yet. This is an independent community project, not affiliated with Bambu Lab or Nextcloud.

## What it does

- Uploads new `.3mf` files, and updates files whose content changed on the printer.
- Ignores everything else: timelapse videos, thumbnails, G-code, temporary files.
- Never uploads a file that is still being written.
- Never uploads the same content twice, also after restarts or a lost state file.
- Never deletes anything, neither on the printer nor in Nextcloud.

## Quick start

You need Docker with Compose, the printer's IP address or host name, its **LAN access code**, and a Nextcloud **app password** (Nextcloud → Personal settings → Security → Devices & sessions).

```sh
mkdir bambu-nextcloud-sync && cd bambu-nextcloud-sync
curl -fsSLO https://raw.githubusercontent.com/stefanwendelmann/bambu-nextcloud-sync/main/compose.yaml
curl -fsSL https://raw.githubusercontent.com/stefanwendelmann/bambu-nextcloud-sync/main/.env.example -o .env
```

Edit `.env` and replace the five `REPLACE_ME` values. For a real printer also set `BAMBU_TLS_INSECURE=true`, see [Printer certificate](#printer-certificate).

```dotenv
BAMBU_HOST=192.168.1.50
BAMBU_ACCESS_CODE=12345678
NEXTCLOUD_WEBDAV_URL=https://nextcloud.example.com/remote.php/dav/files/alice/
NEXTCLOUD_USERNAME=alice
NEXTCLOUD_APP_PASSWORD=xxxxx-xxxxx-xxxxx-xxxxx-xxxxx
BAMBU_TLS_INSECURE=true
```

Preview first, without changing anything:

```sh
docker compose run --rm -e DRY_RUN=true -e RUN_ONCE=true bambu-nextcloud-sync
```

Then start the service and watch it:

```sh
docker compose up -d
docker compose logs -f
```

A successful cycle ends with a line like `cycle_complete result="ok" scanned="12" uploaded="12" …`. Update later with `docker compose pull && docker compose up -d`.

### The WebDAV URL

`NEXTCLOUD_WEBDAV_URL` is not the address you open in the browser. In Nextcloud, open **Files → Files settings (bottom left) → WebDAV** and copy the address shown there. It ends in `/remote.php/dav/files/<your user>/`. Sub folders belong into `NEXTCLOUD_FOLDER`.

## Configuration

All settings are environment variables, normally set in `.env`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `BAMBU_HOST` | required | Printer host name or IP address |
| `BAMBU_PORT` | `990` | Implicit FTPS port |
| `BAMBU_USERNAME` | `bblp` | FTP user |
| `BAMBU_ACCESS_CODE` | required | The printer's LAN access code |
| `BAMBU_SOURCE_PATH` | `/` | Directory on the printer |
| `BAMBU_TLS_INSECURE` | `false` | `true` accepts the printer's unverifiable certificate, for the printer connection only |
| `NEXTCLOUD_WEBDAV_URL` | required | `https://…/remote.php/dav/files/USERNAME/` |
| `NEXTCLOUD_USERNAME` | required | Nextcloud login name |
| `NEXTCLOUD_APP_PASSWORD` | required | Nextcloud app password |
| `NEXTCLOUD_FOLDER` | `3D Druck/Bambu P2S/Projekte` | Target folder inside your files. The account root is not accepted |
| `NEXTCLOUD_CA_CERT_FILE` | empty | PEM file with a private CA for the Nextcloud server |
| `SCAN_MODE` | `root` | `root`: files directly in the source directory. `recursive`: sub folders too, keeping the folder structure |
| `CONFLICT_MODE` | `version` | What happens when the target file exists with different content, see below |
| `SYNC_INTERVAL` | `300` | Seconds between sync runs |
| `STABILITY_CHECK_INTERVAL` | `30` | Seconds between the two listings that must agree before a file is transferred |
| `DRY_RUN` | `false` | Report what would be transferred; change nothing |
| `RUN_ONCE` | `false` | Run one cycle and exit. Exit code `0` means no errors |
| `LOG_LEVEL` | `info` | `error`, `warn`, `info` or `debug` |
| `TZ` | `UTC` | Time zone of the log timestamps |
| `DATA_DIR` | `/data` | State and staging directory inside the container |

Reserved for features that are **not implemented yet**: `SYNC_MODE` (only `archive`), `MIRROR_MODE`, `EXTRACT_METADATA` (only `false`), `MAX_DELETE_COUNT`, `MAX_DELETE_PERCENT`, `ALLOW_EMPTY_SOURCE_MIRROR`. With `SYNC_MODE=mirror` or `EXTRACT_METADATA=true` the service refuses to start.

Check a configuration without connecting anywhere:

```sh
docker compose run --rm bambu-nextcloud-sync --check-config
```

### When the file already exists in Nextcloud

If the existing file has exactly the same content, nothing is uploaded in any mode. Otherwise `CONFLICT_MODE` decides:

| Mode | Behaviour |
| --- | --- |
| `version` | Updates the file under the same name, **only** if Nextcloud confirms that its Versions app is active, so the previous content stays available as a version. If the app is off or cannot be checked, the file is left untouched and the cycle reports an error. |
| `overwrite` | Updates the file under the same name without that check. |
| `skip` | Leaves the existing file as it is and logs a warning. |

How long Nextcloud keeps old versions is decided by the server's own retention rules and your storage quota, not by this service.

## How it works

1. **List.** The complete source directory is listed. If the listing fails, the cycle ends without touching anything.
2. **Wait.** Files that are new or changed are listed a second time after `STABILITY_CHECK_INTERVAL`. Only files with identical size and time in both listings continue.
3. **Stage.** The file is downloaded into `data/staging`. Its size is compared, the printer is listed once more to make sure the file did not change meanwhile, and a SHA-256 checksum is computed.
4. **Compare.** The destination is checked. Identical content is recognised by checksum; if Nextcloud has none, the destination file is hashed.
5. **Upload and verify.** The file is uploaded, then its size and checksum are read back from Nextcloud.
6. **Record.** Only now the file is written to `data/state/manifest.json`, and the staged copy is removed.

If anything fails, the staged copy is kept and the next cycle continues where it stopped. If the state file is lost or damaged, existing Nextcloud files are recognised by their content and not uploaded again.

## Printer certificate

Bambu Lab printers encrypt the connection with a self-signed certificate that does not match their address, so it cannot be verified the usual way. By default the service therefore refuses to connect and tells you so. Setting `BAMBU_TLS_INSECURE=true` accepts the printer's certificate without verification.

This applies to the printer connection only. The connection to Nextcloud is always verified. Use it on a network you trust, and never expose the printer's FTPS port to the internet. Pinning the printer certificate is not available yet.

## Known limitations

- **No mirror mode and no metadata extraction.** Nothing is ever deleted in Nextcloud.
- **Change detection uses the size and time reported by the printer.** A file that changes while keeping both is not noticed.
- **Files you delete in Nextcloud stay deleted** until the file changes on the printer. To have everything re-examined, stop the container and remove `data/state/manifest.json`.
- **A file that cannot be uploaded is retried every cycle**, for example a name Nextcloud does not allow. There is no growing delay.
- **Run one container per data directory.** A second one refuses to start.
- **No container health check yet.** Use the logs, or `RUN_ONCE=true` with its exit code.
- `http://` WebDAV URLs are accepted with a warning; the app password then travels unencrypted.

## Troubleshooting

| Log event | What to do |
| --- | --- |
| `config_invalid` | The message names the variable and the problem. Fix `.env`, then `docker compose up -d`. |
| `printer_certificate_untrusted` | Set `BAMBU_TLS_INSECURE=true`, see [Printer certificate](#printer-certificate). |
| `source_listing_failed` | Printer off or unreachable, wrong address, or wrong access code. The details follow in the same line. Nothing was changed; the next cycle retries. |
| `destination_check_failed`, `upload_failed` | Nextcloud unreachable, wrong URL, user or app password, or no write permission for the folder. |
| `version_guard_blocked` | Enable the **Versions** app in Nextcloud, or choose `CONFLICT_MODE=overwrite` or `skip`. |
| `source_file_not_stable` | Normal while a file is being written. It is picked up once it stops changing. |
| `already_running` | Another container uses the same `data` directory. |

`LOG_LEVEL=debug` adds the rclone error output for failed steps. Credentials are removed from log lines.

## Validation status

Run on every change, on amd64 (unit tests also on arm64):

- Unit tests of configuration validation, logging, state handling and file selection.
- End-to-end tests against **vsftpd** configured like the printer (implicit FTPS on port 990, self-signed certificate, mandatory TLS session reuse, read-only) and a **real Nextcloud 35** server: first sync, unchanged repeat, lost and damaged state, a file that is still growing, all three conflict modes including Nextcloud versions for small and chunked uploads, recursive scan, printer or Nextcloud unavailable, stop signal, and a check that no modifying FTP command is ever sent.

Not covered by automated tests: a physical printer, `NEXTCLOUD_CA_CERT_FILE`, and Nextcloud versions other than the one in `tests/integration/compose.yaml`.

Before you rely on it, do one dry run and one real run against a test folder.

## Development

```sh
docker build --target test .                       # unit tests
docker build -t bambu-nextcloud-sync:test .
bash tests/integration/run.sh                      # end-to-end tests, needs Docker Compose
```

Images are published by GitHub Actions only after all tests passed, to `ghcr.io/stefanwendelmann/bambu-nextcloud-sync`: `latest` follows the `main` branch, version tags such as `1.2.3` mark releases. See [CHANGELOG.md](CHANGELOG.md) and [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
