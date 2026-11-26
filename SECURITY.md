# Security

## Reporting a vulnerability

Please report security problems privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue, and never include access codes, app passwords or `.env` files in a report.

Fixes are made for the latest released version.

## How credentials are handled

- The printer access code and the Nextcloud app password are read from environment variables. Keep them in `.env`, which is excluded from Git, and restrict who can read that file and who can run `docker inspect` on the host.
- rclone receives the credentials through environment variables, not through command line arguments. rclone requires passwords in its "obscured" form; that is an encoding, not encryption, and offers no protection against someone who can read the container's environment.
- For one request to the Nextcloud capabilities API the credentials are written to a file that only the service can read, in the container's temporary directory, and removed right after the request.
- Both secrets are removed from every log line before it is written.
- Use a dedicated Nextcloud app password, so that it can be revoked without changing the account password.

## Network security

- **Nextcloud:** TLS certificates are always verified. A private CA can be supplied with `NEXTCLOUD_CA_CERT_FILE`. `RCLONE_*` environment variables passed to the container are ignored, so verification cannot be switched off by accident. Plain `http://` is accepted only with a warning and should stay inside a private container network.
- **Printer:** Bambu Lab printers use a self-signed certificate that cannot be verified. The connection is refused unless `BAMBU_TLS_INSECURE=true` is set, which disables verification for the printer connection only. In that mode someone on the same network could impersonate the printer and learn the access code. Certificate pinning is not implemented. Keep the printer on a trusted network and never expose its FTPS port to the internet.

## Data safety

- The printer is read-only by design: the service lists and downloads, and has no code path that writes, renames or deletes there.
- This version never deletes anything in Nextcloud. Existing files are replaced only as described for `CONFLICT_MODE` in the README.
- The container runs with a read-only root file system, without Linux capabilities and with `no-new-privileges` in the provided `compose.yaml`. It needs write access only to the `/data` volume.
