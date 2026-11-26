#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted snippets are expanded inside the containers
#
# End-to-end tests: the image under test against a printer stand-in (vsftpd with implicit
# FTPS, like a Bambu Lab printer) and a real Nextcloud server.
#
#   docker build -t bambu-nextcloud-sync:test .
#   bash tests/integration/run.sh
#
# KEEP=1 leaves the containers running for inspection.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

export MSYS_NO_PATHCONV=1 # Git Bash on Windows must not rewrite container paths
export SYNC_IMAGE=${SYNC_IMAGE:-bambu-nextcloud-sync:test}

# Throwaway credentials, generated per run and never written to the repository.
random_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
FTP_PASSWORD="code-$(random_hex 6)"
NC_PASSWORD="Nc-$(random_hex 14)"
export FTP_PASSWORD NC_PASSWORD

LOG_DIR=$(mktemp -d)
FOLDER='3D Druck/Bambu P2S/Projekte'
NC_FILES=/var/www/html/data/admin/files
NC_VERSIONS=/var/www/html/data/admin/files_versions
LOOP_CONTAINER=bambu-nextcloud-sync-integration-loop
UMLAUT='B\303\274gel (v2).3mf' # printf format; expanded to UTF-8 inside the containers
CHECKS=0
FAILED=0
SYNC_LOG=
SYNC_RC=0

dc() { docker compose --profile sync "$@"; }

finish() {
  if [ "${KEEP:-0}" != 1 ]; then
    docker rm -f "$LOOP_CONTAINER" >/dev/null 2>&1
    dc down -v --remove-orphans >/dev/null 2>&1
  fi
  rm -rf "$LOG_DIR"
}
trap finish EXIT

# ---------------------------------------------------------------------- helpers

section() { printf '\n== %s\n' "$1"; }
pass() {
  CHECKS=$((CHECKS + 1))
  printf '  ok   %s\n' "$1"
}
fail() {
  CHECKS=$((CHECKS + 1))
  FAILED=$((FAILED + 1))
  printf '  FAIL %s\n' "$1"
  [ -z "$SYNC_LOG" ] || sed 's/^/       | /' "$SYNC_LOG"
}
check() {
  local description=$1
  shift
  if "$@"; then pass "$description"; else fail "$description"; fi
}
check_not() {
  local description=$1
  shift
  if "$@"; then fail "$description"; else pass "$description"; fi
}
expect_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# sync_run NAME [VARIABLE=VALUE...] -> one RUN_ONCE cycle; sets SYNC_LOG and SYNC_RC.
sync_run() {
  local name=$1 setting args=()
  shift
  for setting in "$@"; do args+=(-e "$setting"); done
  SYNC_LOG="$LOG_DIR/$name.log"
  dc run --rm -T ${args[@]+"${args[@]}"} sync >"$SYNC_LOG" 2>&1 </dev/null
  SYNC_RC=$?
}
succeeded() { [ "$SYNC_RC" -eq 0 ]; }
logged() { grep -Eq -- "$1" "$SYNC_LOG"; }
log_count() { grep -Ec -- "$1" "$SYNC_LOG" || true; }

# The persistent /data volume of the service.
data_sh() { dc run --rm -T --entrypoint sh sync -c "$1" </dev/null 2>/dev/null | tr -d '\r'; }

# The printer stand-in. Test files are placed directly on its disk, never through FTP.
printer() { dc exec -T ftps sh -c "$1" </dev/null | tr -d '\r'; }
printer_put() {
  dc exec -T -e NAME="$1" ftps sh -c \
    'file="/srv/ftp/$(printf "$NAME")"; mkdir -p "$(dirname "$file")" && '"$2"' >"$file"' </dev/null
}
printer_sha() {
  dc exec -T -e NAME="$1" ftps sh -c 'sha256sum "/srv/ftp/$(printf "$NAME")" | cut -d" " -f1' </dev/null | tr -d '\r'
}
printer_fingerprint() {
  printer 'cd /srv/ftp && find . -exec stat -c "%n %s %Y %a %U" {} + | sort | sha256sum | cut -d" " -f1'
}

# The Nextcloud data directory, inspected on disk (independent of WebDAV and rclone).
cloud() {
  dc exec -T -u www-data -e DIR="$NC_FILES/$FOLDER" -e VERSIONS="$NC_VERSIONS/$FOLDER" -e NAME="${2:-}" \
    nextcloud sh -c "$1" </dev/null | tr -d '\r'
}
cloud_sha() { cloud 'sha256sum "$DIR/$(printf "$NAME")" 2>/dev/null | cut -d" " -f1' "$1"; }
cloud_has() { [ "$(cloud 'test -f "$DIR/$(printf "$NAME")" && echo yes' "$1")" = yes ]; }
cloud_file_count() { cloud 'find "$DIR" -type f 2>/dev/null | wc -l' | tr -d ' '; }
cloud_versions() { cloud 'find "$VERSIONS" -type f -name "$(printf "$NAME").v*" 2>/dev/null | wc -l' "$1" | tr -d ' '; }
occ() { dc exec -T -u www-data nextcloud php occ "$@" </dev/null >/dev/null 2>&1; }

same_content() {
  local source target
  source=$(printer_sha "$1")
  target=$(cloud_sha "$1")
  [ -n "$source" ] && [ "$source" = "$target" ]
}

wait_until() {
  local tries=$1
  shift
  while [ "$tries" -gt 0 ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    tries=$((tries - 1))
    sleep 3
  done
  return 1
}
nextcloud_ready() {
  dc exec -T nextcloud php -r 'echo @file_get_contents("http://localhost/status.php");' </dev/null | grep -q '"installed":true'
}
printer_ready() { dc exec -T ftps sh -c 'nc -z 127.0.0.1 990' </dev/null; }

# ------------------------------------------------------------------ environment

section "Starting printer stand-in and Nextcloud"
dc down -v --remove-orphans >/dev/null 2>&1
if ! dc up -d --build ftps nextcloud >"$LOG_DIR/up.log" 2>&1; then
  cat "$LOG_DIR/up.log"
  echo "Could not start the test environment."
  exit 1
fi
check "printer stand-in accepts connections" wait_until 20 printer_ready
check "Nextcloud is installed" wait_until 100 nextcloud_ready

printer_put 'plate one.3mf' 'printf model-one'
printer_put "$UMLAUT" 'printf model-buegel'
printer_put 'UPPER.3MF' 'printf model-upper'
printer_put 'big.3mf' 'head -c 12582912 /dev/urandom' # above the 10 MiB chunked upload threshold
printer_put 'nested/inner.3mf' 'printf model-inner'
printer_put 'notes.gcode' 'printf gcode'
printer_put 'timelapse/video_2026-11-21_20-58-28.mp4' 'printf video'
printer_put 'timelapse/tmp.video' 'printf recording'
printer_put 'timelapse/thumbnail/video_2026-11-21_20-58-28.jpg' 'printf thumbnail'

# ---------------------------------------------------------------------- startup

section "Printer certificate is verified unless explicitly trusted"
sync_run tls-default BAMBU_TLS_INSECURE=false
check_not "self-signed printer certificate is rejected by default" succeeded
check "the log explains the opt-in" logged 'printer_certificate_untrusted'

section "Wrong printer access code"
sync_run wrong-code BAMBU_ACCESS_CODE=not-the-code
check_not "cycle fails" succeeded
check "listing failure is reported" logged 'source_listing_failed'

section "Dry run changes nothing"
sync_run dry-run DRY_RUN=true
check "cycle succeeds" succeeded
expect_eq "root .3mf files are planned" 4 "$(log_count 'dry_run_would_upload')"
expect_eq "nothing arrives in Nextcloud" 0 "$(cloud_file_count)"
expect_eq "no state is recorded" '' "$(data_sh 'test -e /data/state/manifest.json && echo present')"
expect_eq "nothing is staged" 0 "$(data_sh 'ls /data/staging | wc -l' | tr -d ' ')"

# ------------------------------------------------------------------ archive sync

section "First sync (root scan, archive mode)"
fingerprint=$(printer_fingerprint)
sync_run first
check "cycle succeeds" succeeded
expect_eq "four files uploaded" 4 "$(log_count ' uploaded file=')"
check "file name with spaces is identical" same_content 'plate one.3mf'
check "file name with umlaut is identical" same_content "$UMLAUT"
check "upper-case extension is identical" same_content 'UPPER.3MF'
check "12 MiB file (chunked upload) is identical" same_content 'big.3mf'
expect_eq "only the root .3mf files exist in Nextcloud" 4 "$(cloud_file_count)"
expect_eq "printer files are untouched" "$fingerprint" "$(printer_fingerprint)"
expect_eq "staging is empty afterwards" 0 "$(data_sh 'ls /data/staging | wc -l' | tr -d ' ')"

section "Repeated run without changes"
sync_run repeat LOG_LEVEL=debug
check "cycle succeeds" succeeded
expect_eq "nothing is downloaded" 0 "$(log_count ' downloaded file=')"
expect_eq "nothing is uploaded" 0 "$(log_count ' (uploaded|version_updated|overwritten) file=')"
expect_eq "no Nextcloud version is created" 0 "$(cloud_versions 'plate one.3mf')"

section "Lost state is rebuilt without uploading again"
data_sh 'rm -f /data/state/manifest.json'
sync_run state-lost
check "cycle succeeds" succeeded
expect_eq "existing destination files are recognised by content" 4 "$(log_count 'destination_already_current')"
expect_eq "nothing is uploaded" 0 "$(log_count ' (uploaded|version_updated|overwritten) file=')"
expect_eq "no Nextcloud version is created" 0 "$(cloud_versions 'big.3mf')"
expect_eq "re-identified files are not claimed as managed" false \
  "$(data_sh 'jq -r "[.items[].managed_by_service] | unique | join(\",\")" /data/state/manifest.json')"

section "Corrupt state is set aside"
data_sh 'printf "{\"schema_version\":1,\"items\":{" >/data/state/manifest.json'
sync_run state-corrupt
check "cycle succeeds" succeeded
check "corruption is reported" logged 'state_corrupt_quarantined'
expect_eq "nothing is uploaded" 0 "$(log_count ' (uploaded|version_updated|overwritten) file=')"
expect_eq "damaged manifest is kept for diagnosis" 1 "$(data_sh 'ls /data/state | grep -c corrupt')"

section "File still being written"
dc exec -T ftps sh -c 'i=0; while [ "$i" -lt 40 ]; do printf xxxxxxxx >>/srv/ftp/growing.3mf; i=$((i + 1)); sleep 0.5; done' </dev/null &
writer=$!
sleep 2
sync_run growing
check "cycle succeeds" succeeded
check "growing file is reported as not stable" logged 'source_file_not_stable file="growing.3mf"'
check_not "growing file is not uploaded" cloud_has 'growing.3mf'
wait "$writer"
sync_run grown
check "finished file is uploaded" logged ' uploaded file="growing.3mf"'
check "finished file is identical" same_content 'growing.3mf'

# ---------------------------------------------------------------- conflict modes

section "CONFLICT_MODE=version: changed files become new Nextcloud versions"
printer_put 'plate one.3mf' 'printf model-one-revision-2'
printer 'head -c 1048576 /dev/urandom >>/srv/ftp/big.3mf'
files_before=$(cloud_file_count)
sync_run version-update
check "cycle succeeds" succeeded
expect_eq "both changed files are updated in place" 2 "$(log_count ' version_updated file=')"
check "small file has the new content" same_content 'plate one.3mf'
check "chunked file has the new content" same_content 'big.3mf'
expect_eq "previous small file is kept as a version" 1 "$(cloud_versions 'plate one.3mf')"
expect_eq "previous chunked file is kept as a version" 1 "$(cloud_versions 'big.3mf')"
expect_eq "previous content is what the version holds" model-one "$(cloud 'cat "$VERSIONS/plate one.3mf.v"*')"
expect_eq "no additional file names appear" "$files_before" "$(cloud_file_count)"

section "Existing destination files that Nextcloud has no checksum for"
printer_put 'same.3mf' 'printf identical-bytes'
printer_put 'foreign.3mf' 'printf printer-edition'
cloud 'printf identical-bytes >"$DIR/same.3mf"; printf users-own-edition >"$DIR/foreign.3mf"'
occ files:scan admin
sync_run existing
check "cycle succeeds" succeeded
check "identical file is recognised by hashing the destination" \
  logged 'destination_already_current file="same.3mf".*verified_by="sha256"'
expect_eq "identical file gets no version" 0 "$(cloud_versions 'same.3mf')"
check "different file is updated" logged ' version_updated file="foreign.3mf"'
expect_eq "the user's edition is kept as a version" users-own-edition "$(cloud 'cat "$VERSIONS/foreign.3mf.v"*')"

section "CONFLICT_MODE=version refuses to overwrite without the Versions app"
occ app:disable files_versions
printer_put 'UPPER.3MF' 'printf model-upper-revision-2'
printer_put 'fresh.3mf' 'printf model-fresh'
upper_before=$(cloud_sha 'UPPER.3MF')
sync_run version-guard
check_not "cycle reports failure" succeeded
check "overwrite is blocked" logged 'version_guard_blocked file="UPPER.3MF".*nextcloud_versioning="disabled"'
expect_eq "existing file keeps its content" "$upper_before" "$(cloud_sha 'UPPER.3MF')"
check "new file names are still uploaded" logged ' uploaded file="fresh.3mf"'
sync_run version-guard-repeat
check "staged copy is reused instead of downloading again" logged 'staged_file_reused file="UPPER.3MF"'
expect_eq "existing file still keeps its content" "$upper_before" "$(cloud_sha 'UPPER.3MF')"
occ app:enable files_versions
sync_run version-guard-lifted
check "cycle succeeds once versioning is back" succeeded
check "file is updated" same_content 'UPPER.3MF'

section "CONFLICT_MODE=skip keeps existing destination files"
printer_put "$UMLAUT" 'printf model-buegel-revision-2'
umlaut_before=$(cloud_sha "$UMLAUT")
sync_run skip CONFLICT_MODE=skip
check "cycle succeeds" succeeded
check "skip is logged" logged 'conflict_skipped'
expect_eq "existing file keeps its content" "$umlaut_before" "$(cloud_sha "$UMLAUT")"
sync_run skip-repeat CONFLICT_MODE=skip
expect_eq "skipped file is not downloaded again" 0 "$(log_count ' downloaded file=')"

section "CONFLICT_MODE=overwrite replaces existing destination files"
sync_run overwrite CONFLICT_MODE=overwrite
check "cycle succeeds" succeeded
check "overwrite is logged" logged ' overwritten file='
check "file has the new content" same_content "$UMLAUT"

# -------------------------------------------------------------------- scan modes

section "SCAN_MODE=recursive"
sync_run recursive SCAN_MODE=recursive
check "cycle succeeds" succeeded
check "nested project is uploaded" logged ' uploaded file="nested/inner.3mf"'
expect_eq "sub folder structure is preserved" yes "$(cloud 'test -f "$DIR/nested/inner.3mf" && echo yes')"
expect_eq "videos, thumbnails and G-code are never uploaded" 0 "$(cloud 'find "$DIR" -type f ! -iname "*.3mf" | wc -l' | tr -d ' ')"

# ---------------------------------------------------------------------- failures

section "Nextcloud unavailable"
printer_put 'offline.3mf' 'printf made-while-nextcloud-was-down'
dc stop nextcloud >/dev/null 2>&1
sync_run nextcloud-down
check_not "cycle reports failure" succeeded
expect_eq "file is not recorded as synced" none "$(data_sh 'jq -r ".items[\"offline.3mf\"] // \"none\"" /data/state/manifest.json')"
dc start nextcloud >/dev/null 2>&1
check "Nextcloud is back" wait_until 60 nextcloud_ready
sync_run nextcloud-back
check "cycle succeeds" succeeded
check "staged copy is reused" logged 'staged_file_reused file="offline.3mf"'
check "file arrives" same_content 'offline.3mf'

section "Printer unavailable"
files_before=$(cloud_file_count)
dc stop ftps >/dev/null 2>&1
sync_run printer-down
check_not "cycle reports failure" succeeded
check "listing failure is reported" logged 'source_listing_failed'
expect_eq "Nextcloud files are untouched" "$files_before" "$(cloud_file_count)"
dc start ftps >/dev/null 2>&1
check "printer stand-in is back" wait_until 20 printer_ready

# ----------------------------------------------------------------------- service

section "Single instance and graceful stop"
docker rm -f "$LOOP_CONTAINER" >/dev/null 2>&1
dc run -d --name "$LOOP_CONTAINER" -e RUN_ONCE=false -e SYNC_INTERVAL=3600 sync >/dev/null 2>&1
loop_idle() { docker logs "$LOOP_CONTAINER" 2>&1 | grep -q 'cycle_complete'; }
check "service keeps running after a cycle" wait_until 20 loop_idle
sync_run second-instance
check_not "second instance on the same data volume is refused" succeeded
check "refusal is explained" logged 'already_running'
stop_started=$(date +%s)
docker stop -t 25 "$LOOP_CONTAINER" >/dev/null 2>&1
stop_seconds=$(($(date +%s) - stop_started))
SYNC_LOG="$LOG_DIR/loop.log"
docker logs "$LOOP_CONTAINER" >"$SYNC_LOG" 2>&1
check "service stops promptly on SIGTERM (${stop_seconds}s)" [ "$stop_seconds" -lt 10 ]
check "service reports a clean stop" logged 'service_stopped'
expect_eq "exit code after SIGTERM" 0 "$(docker inspect -f '{{.State.ExitCode}}' "$LOOP_CONTAINER")"

section "Same data volume, different destination folder"
files_before=$(cloud_file_count)
# RCLONE_DRY_RUN would stop rclone from uploading if user supplied rclone settings were honoured.
sync_run other-folder 'NEXTCLOUD_FOLDER=Archive/Second Target' RCLONE_DRY_RUN=true
check "cycle succeeds" succeeded
check "old state is set aside instead of being trusted" logged 'state_destination_changed'
check "user supplied rclone settings are ignored" logged 'rclone_env_ignored variable="RCLONE_DRY_RUN"'
expect_eq "files are uploaded to the new folder" yes \
  "$(dc exec -T -u www-data nextcloud sh -c "test -f '$NC_FILES/Archive/Second Target/plate one.3mf' && echo yes" </dev/null | tr -d '\r')"
expect_eq "first folder is untouched" "$files_before" "$(cloud_file_count)"

# ------------------------------------------------------------------------ safety

section "Secrets and printer safety"
SYNC_LOG=
check_not "no credential appears in any log" grep -rqF -e "$FTP_PASSWORD" -e "$NC_PASSWORD" "$LOG_DIR"
expect_eq "no modifying FTP command was ever sent to the printer" 0 \
  "$(printer 'grep -Eic "FTP command: Client \"[^\"]*\", \"(STOR|STOU|APPE|DELE|RNFR|RNTO|MKD|RMD|MFMT|SITE) " /var/log/vsftpd.log')"
check "the protocol log did record the downloads" [ "$(printer 'grep -c "\"RETR " /var/log/vsftpd.log')" -gt 0 ]

printf '\n%s checks, %s failed\n' "$CHECKS" "$FAILED"
[ "$FAILED" -eq 0 ]
