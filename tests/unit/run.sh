#!/bin/sh
# Unit tests for the shell modules. They run inside the runtime image, against the same
# BusyBox, jq and rclone the service uses:  docker build --target test .
set -u

APP_DIR=${APP_DIR:-/app}
TESTS=0
FAILURES=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ok() { TESTS=$((TESTS + 1)); }
fail() {
  TESTS=$((TESTS + 1))
  FAILURES=$((FAILURES + 1))
  printf 'FAIL: %s\n' "$1"
}
expect_eq() {
  if [ "$2" = "$3" ]; then ok; else fail "$1 (expected '$2', got '$3')"; fi
}
expect_true() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok; else fail "$description"; fi
}
expect_false() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then fail "$description"; else ok; fi
}

# ---------------------------------------------------------------- configuration

check_config() {
  env -i PATH="$PATH" BAMBU_HOST=printer.lan BAMBU_ACCESS_CODE=87654321 \
    NEXTCLOUD_WEBDAV_URL=https://cloud.example.com/remote.php/dav/files/alice/ \
    NEXTCLOUD_USERNAME=alice NEXTCLOUD_APP_PASSWORD=app-password-123 \
    "$@" sh "$APP_DIR/entrypoint.sh" --check-config 2>&1
}
accepts() {
  local description="$1"
  shift
  if check_config "$@" >/dev/null; then ok; else fail "config accepted: $description"; fi
}
rejects() {
  local description="$1" text="$2" output
  shift 2
  if output=$(check_config "$@"); then
    fail "config rejected: $description (it was accepted)"
    return
  fi
  case "$output" in
    *"$text"*) ok ;;
    *) fail "config rejected: $description (no '$text' in: $output)" ;;
  esac
}
# loaded VARIABLE [NAME=VALUE...] -> prints the value of VARIABLE after config_load.
loaded() {
  local variable="$1"
  shift
  # shellcheck disable=SC2016  # expanded by the inner shell
  env -i PATH="$PATH" APP_DIR="$APP_DIR" PRINT="$variable" BAMBU_HOST=printer.lan BAMBU_ACCESS_CODE=87654321 \
    NEXTCLOUD_WEBDAV_URL=https://cloud.example.com/remote.php/dav/files/alice/ \
    NEXTCLOUD_USERNAME=alice NEXTCLOUD_APP_PASSWORD=app-password-123 \
    "$@" sh -c '. "$APP_DIR/log.sh"; . "$APP_DIR/config.sh"
      config_load >/dev/null 2>&1 || exit 1
      eval "printf %s \"\$$PRINT\""'
}

accepts "minimal configuration"
expect_eq "default port" 990 "$(loaded BAMBU_PORT)"
expect_eq "default user" bblp "$(loaded BAMBU_USERNAME)"
expect_eq "default source path" / "$(loaded BAMBU_SOURCE_PATH)"
expect_eq "default folder" '3D Druck/Bambu P2S/Projekte' "$(loaded NEXTCLOUD_FOLDER)"
expect_eq "default scan mode" root "$(loaded SCAN_MODE)"
expect_eq "default sync mode" archive "$(loaded SYNC_MODE)"
expect_eq "default conflict mode" version "$(loaded CONFLICT_MODE)"
expect_eq "default interval" 300 "$(loaded SYNC_INTERVAL)"
expect_eq "default stability interval" 30 "$(loaded STABILITY_CHECK_INTERVAL)"
expect_eq "default dry run" false "$(loaded DRY_RUN)"
expect_eq "printer TLS verified by default" false "$(loaded BAMBU_TLS_INSECURE)"
expect_eq "empty value falls back to default" root "$(loaded SCAN_MODE SCAN_MODE=)"

rejects "missing printer host" BAMBU_HOST BAMBU_HOST=
rejects "missing access code" BAMBU_ACCESS_CODE BAMBU_ACCESS_CODE=
rejects "missing WebDAV URL" NEXTCLOUD_WEBDAV_URL NEXTCLOUD_WEBDAV_URL=
rejects "missing Nextcloud user" NEXTCLOUD_USERNAME NEXTCLOUD_USERNAME=
rejects "missing app password" NEXTCLOUD_APP_PASSWORD NEXTCLOUD_APP_PASSWORD=
rejects "placeholder access code" placeholder BAMBU_ACCESS_CODE=REPLACE_ME
rejects "placeholder app password" placeholder NEXTCLOUD_APP_PASSWORD=REPLACE_ME

rejects "host with scheme" BAMBU_HOST BAMBU_HOST=ftps://192.168.1.50
rejects "host with path" BAMBU_HOST BAMBU_HOST=192.168.1.50/timelapse
accepts "IPv4 host" BAMBU_HOST=192.168.1.50
rejects "port zero" BAMBU_PORT BAMBU_PORT=0
rejects "port too large" BAMBU_PORT BAMBU_PORT=70000
rejects "port not numeric" BAMBU_PORT BAMBU_PORT=ftps

rejects "relative source path" BAMBU_SOURCE_PATH BAMBU_SOURCE_PATH=models
rejects "source path traversal" BAMBU_SOURCE_PATH BAMBU_SOURCE_PATH=/models/../timelapse
expect_eq "source path trailing slash" /models "$(loaded BAMBU_SOURCE_PATH BAMBU_SOURCE_PATH=/models/)"

rejects "browser URL instead of WebDAV URL" NEXTCLOUD_WEBDAV_URL NEXTCLOUD_WEBDAV_URL=https://cloud.example.com/
rejects "URL below the user root" NEXTCLOUD_FOLDER \
  NEXTCLOUD_WEBDAV_URL=https://cloud.example.com/remote.php/dav/files/alice/Documents
rejects "URL with credentials" credentials \
  NEXTCLOUD_WEBDAV_URL=https://alice:secret@cloud.example.com/remote.php/dav/files/alice/
rejects "URL with other scheme" NEXTCLOUD_WEBDAV_URL \
  NEXTCLOUD_WEBDAV_URL=ftp://cloud.example.com/remote.php/dav/files/alice/
rejects "URL with query" NEXTCLOUD_WEBDAV_URL \
  'NEXTCLOUD_WEBDAV_URL=https://cloud.example.com/remote.php/dav/files/alice/?x=1'
expect_eq "URL normalised" https://cloud.example.com/remote.php/dav/files/alice/ \
  "$(loaded NEXTCLOUD_WEBDAV_URL NEXTCLOUD_WEBDAV_URL=https://cloud.example.com/remote.php/dav/files/alice)"
expect_eq "base URL of sub path installation" https://example.com/nextcloud \
  "$(loaded NEXTCLOUD_BASE_URL NEXTCLOUD_WEBDAV_URL=https://example.com/nextcloud/remote.php/dav/files/alice/)"
expect_eq "e-mail style user id in URL" https://example.com \
  "$(loaded NEXTCLOUD_BASE_URL NEXTCLOUD_WEBDAV_URL=https://example.com/remote.php/dav/files/alice@example.com/)"
expect_eq "plain http is flagged" true \
  "$(loaded NEXTCLOUD_PLAIN_HTTP NEXTCLOUD_WEBDAV_URL=http://nextcloud/remote.php/dav/files/alice/)"
expect_eq "https is not flagged" false "$(loaded NEXTCLOUD_PLAIN_HTTP)"

rejects "account root as folder" "account root" NEXTCLOUD_FOLDER=/
rejects "folder traversal" NEXTCLOUD_FOLDER NEXTCLOUD_FOLDER=../other
rejects "folder traversal inside" NEXTCLOUD_FOLDER NEXTCLOUD_FOLDER=Projects/../../other
rejects "folder with dot segment" NEXTCLOUD_FOLDER NEXTCLOUD_FOLDER=Projects/./x
rejects "folder with empty segment" NEXTCLOUD_FOLDER NEXTCLOUD_FOLDER=Projects//x
rejects "folder with backslash" NEXTCLOUD_FOLDER 'NEXTCLOUD_FOLDER=Projects\x'
rejects "folder with line break" NEXTCLOUD_FOLDER "NEXTCLOUD_FOLDER=$(printf 'a\nb')"
expect_eq "folder slashes trimmed" 'Prints/3MF Files' "$(loaded NEXTCLOUD_FOLDER 'NEXTCLOUD_FOLDER=/Prints/3MF Files/')"

rejects "unknown scan mode" SCAN_MODE SCAN_MODE=deep
rejects "unknown conflict mode" CONFLICT_MODE CONFLICT_MODE=rename
rejects "unknown mirror mode" MIRROR_MODE MIRROR_MODE=full
rejects "boolean spelled differently" DRY_RUN DRY_RUN=yes
rejects "interval zero" SYNC_INTERVAL SYNC_INTERVAL=0
rejects "interval negative" SYNC_INTERVAL SYNC_INTERVAL=-5
rejects "interval not numeric" SYNC_INTERVAL SYNC_INTERVAL=5m
rejects "delete percent above 100" MAX_DELETE_PERCENT MAX_DELETE_PERCENT=150
rejects "missing CA file" NEXTCLOUD_CA_CERT_FILE NEXTCLOUD_CA_CERT_FILE=/nonexistent/ca.pem
accepts "all conflict modes" CONFLICT_MODE=overwrite
accepts "skip conflict mode" CONFLICT_MODE=skip
accepts "recursive scan" SCAN_MODE=recursive

# Destructive and unfinished features must fail closed instead of half working.
rejects "mirror mode is not available" "not implemented" SYNC_MODE=mirror
rejects "exact mirror is not available" "not implemented" SYNC_MODE=mirror MIRROR_MODE=exact
rejects "metadata extraction is not available" "not implemented" EXTRACT_METADATA=true

case "$(check_config SCAN_MODE=deep)" in
  *87654321* | *app-password-123*) fail "rejected configuration must not print secrets" ;;
  *) ok ;;
esac
env -i PATH="$PATH" sh "$APP_DIR/entrypoint.sh" --unknown >/dev/null 2>&1
expect_eq "unknown argument" 64 "$?"

# ---------------------------------------------------------------------- logging

# shellcheck source=src/log.sh
. "$APP_DIR/log.sh"
export BAMBU_ACCESS_CODE=87654321 NEXTCLOUD_APP_PASSWORD='app pass/+"x'

expect_eq "access code redacted" 'code *** twice ***' "$(printf 'code 87654321 twice 87654321' | sanitize)"
expect_eq "app password redacted" 'pw=***.' "$(printf 'pw=app pass/+"x.' | sanitize)"
expect_eq "control characters removed" 'ab c' "$(printf 'a\rb\tc\033' | tr '\t' ' ' | sanitize)"

LOG_LEVEL_NUM=2
line=$(log info uploaded "file=$(printf 'x.3mf\n2026-01-01T00:00:00+0000 INFO deleted file="all"')" 2>&1)
expect_eq "hostile file name stays on one line" 1 "$(printf '%s\n' "$line" | wc -l | tr -d ' ')"
case "$line" in
  *' INFO uploaded file="x.3mf 2026-01-01T00:00:00+0000 INFO deleted file=\"all\""') ok ;;
  *) fail "quotes escaped inside values: $line" ;;
esac
if printf '%s\n' "$line" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{4} INFO '; then
  ok
else
  fail "timestamp with offset: $line"
fi
expect_eq "debug hidden at info" '' "$(log debug hidden 2>&1)"
expect_eq "secret in log value redacted" 1 "$(log error failed 'detail=login 87654321 rejected' 2>&1 | grep -c 'detail="login \*\*\* rejected"')"
LOG_LEVEL_NUM=-1

# ------------------------------------------------------------------------ state

# shellcheck source=src/config.sh
. "$APP_DIR/config.sh"
# shellcheck source=src/state.sh
. "$APP_DIR/state.sh"

DATA_DIR="$WORK/data"
DRY_RUN=false
NEXTCLOUD_WEBDAV_URL=https://cloud.example.com/remote.php/dav/files/alice/
NEXTCLOUD_FOLDER='3D Druck/Bambu P2S/Projekte'
expect_true "state initialises" state_init
expect_true "staging directory created" test -d "$DATA_DIR/staging"
expect_eq "empty state has no items" 0 "$(state_read | jq '.items | length')"
expect_eq "unknown item" '' "$(state_get missing.3mf)"

expect_true "item stored" state_put 'Bügel (v2) "final".3mf' '{"sha256":"abc","status":"synced"}'
expect_true "second item stored" state_put 'sub/dir/part.3mf' '{"sha256":"def","status":"synced"}'
expect_eq "item read back" abc "$(state_get 'Bügel (v2) "final".3mf' | jq -r '.sha256')"
expect_eq "both items kept" 2 "$(state_read | jq '.items | length')"
expect_eq "manifest schema version" 1 "$(jq '.schema_version' "$STATE_FILE")"
expect_eq "no temporary files left" 0 "$(find "$STATE_DIR" -name '*.tmp' | wc -l | tr -d ' ')"
expect_false "invalid item rejected" state_put broken.3mf '{not json'
expect_eq "manifest intact after rejected write" 2 "$(state_read | jq '.items | length')"

expect_true "restart keeps state" state_init
expect_eq "state survives restart" def "$(state_get 'sub/dir/part.3mf' | jq -r '.sha256')"

# The same data volume pointed at another folder or account must not reuse the old answers.
NEXTCLOUD_FOLDER='Other Folder'
DRY_RUN=true
expect_true "dry run with another destination starts" state_init
expect_eq "dry run ignores the state of another destination" 0 "$(state_read | jq '.items | length')"
expect_eq "dry run leaves the manifest in place" 2 "$(jq '.items | length' "$STATE_DIR/manifest.json")"
DRY_RUN=false
expect_true "other destination does not stop the service" state_init
expect_eq "state of another destination is not reused" 0 "$(state_read | jq '.items | length')"
expect_eq "state of another destination is kept aside" 1 "$(find "$STATE_DIR" -name 'manifest.json.other-destination-*' | wc -l | tr -d ' ')"
expect_true "item stored for the new destination" state_put a.3mf '{"sha256":"abc"}'
expect_eq "manifest names its destination" 'https://cloud.example.com/remote.php/dav/files/alice/Other Folder' "$(jq -r '.destination' "$STATE_FILE")"

(
  state_lock || exit 1
  (state_lock) && exit 1
  exit 0
) 9>/dev/null
expect_eq "second instance is refused" 0 "$?"

printf '{"schema_version":1,"items":{"a.3mf"' >"$STATE_FILE"
expect_true "corrupt manifest does not stop the service" state_init
expect_eq "corrupt manifest replaced by empty state" 0 "$(state_read | jq '.items | length')"
expect_eq "corrupt manifest kept for diagnosis" 1 "$(find "$STATE_DIR" -name 'manifest.json.corrupt-*' | wc -l | tr -d ' ')"

printf '{"schema_version":2,"items":{"a.3mf":{}}}' >"$STATE_FILE"
expect_false "newer manifest refused" state_init
expect_eq "newer manifest untouched" 2 "$(jq '.schema_version' "$STATE_FILE")"
rm -f "$STATE_FILE"

: >"$STAGING_DIR/aaa.3mf.1a2b3c4d.partial"
: >"$STAGING_DIR/orphan.3mf"
: >"$STAGING_DIR/orphan-meta.json"
: >"$STAGING_DIR/kept.3mf"
: >"$STAGING_DIR/kept.json"
staging_cleanup
expect_eq "staging cleanup keeps complete pairs only" 'kept.3mf kept.json' "$(find "$STAGING_DIR" -type f -exec basename {} \; | sort | tr '\n' ' ' | sed 's/ $//')"
rm -f "$STAGING_DIR"/*

# -------------------------------------------------------------------- selection

# shellcheck source=src/process.sh
. "$APP_DIR/process.sh"
# shellcheck source=src/remote.sh
. "$APP_DIR/remote.sh"
# shellcheck source=src/sync.sh
. "$APP_DIR/sync.sh"

paths() { jq -r '[.[].path] | join("|")' "$1"; }

cat >"$WORK/listing.json" <<'EOF'
[
  {"path": "Bügel (v2).3mf", "size": 10, "modtime": "2026-01-01T10:00:00Z"},
  {"path": "UPPER.3MF", "size": 10, "modtime": "2026-01-01T10:00:00Z"},
  {"path": "sub/nested.3mf", "size": 10, "modtime": "2026-01-01T10:00:00Z"},
  {"path": "../escape.3mf", "size": 10, "modtime": "2026-01-01T10:00:00Z"},
  {"path": "sub/../../escape.3mf", "size": 10, "modtime": "2026-01-01T10:00:00Z"},
  {"path": "/absolute.3mf", "size": 10, "modtime": "2026-01-01T10:00:00Z"},
  {"path": "back\\slash.3mf", "size": 10, "modtime": "2026-01-01T10:00:00Z"},
  {"path": "line\nbreak.3mf", "size": 10, "modtime": "2026-01-01T10:00:00Z"},
  {"path": "timelapse/video.mp4", "size": 10, "modtime": "2026-01-01T10:00:00Z"},
  {"path": "plate.gcode", "size": 10, "modtime": "2026-01-01T10:00:00Z"}
]
EOF

SCAN_MODE=root
expect_true "root listing split" split_listing "$WORK/listing.json" "$WORK/in.json" "$WORK/out.json"
expect_eq "root mode scope" 'Bügel (v2).3mf|UPPER.3MF' "$(paths "$WORK/in.json")"
expect_eq "root mode ignores the rest" 8 "$(jq 'length' "$WORK/out.json")"
SCAN_MODE=recursive
expect_true "recursive listing split" split_listing "$WORK/listing.json" "$WORK/in.json" "$WORK/out.json"
expect_eq "recursive mode scope" 'Bügel (v2).3mf|UPPER.3MF|sub/nested.3mf' "$(paths "$WORK/in.json")"
SCAN_MODE=root

cat >"$WORK/scope.json" <<'EOF'
[
  {"path": "new.3mf", "size": 10, "modtime": "2026-01-01T10:00:00Z"},
  {"path": "same.3mf", "size": 20, "modtime": "2026-01-01T10:00:00Z"},
  {"path": "grown.3mf", "size": 31, "modtime": "2026-01-01T10:00:00Z"},
  {"path": "touched.3mf", "size": 40, "modtime": "2026-01-02T10:00:00Z"},
  {"path": "empty.3mf", "size": 0, "modtime": "2026-01-01T10:00:00Z"},
  {"path": "conflict.3mf", "size": 50, "modtime": "2026-01-01T10:00:00Z"}
]
EOF
cat >"$WORK/state.json" <<'EOF'
{"schema_version": 1, "items": {
  "same.3mf": {"source_size": 20, "source_modified_at": "2026-01-01T10:00:00Z", "status": "synced"},
  "grown.3mf": {"source_size": 30, "source_modified_at": "2026-01-01T10:00:00Z", "status": "synced"},
  "touched.3mf": {"source_size": 40, "source_modified_at": "2026-01-01T10:00:00Z", "status": "synced"},
  "conflict.3mf": {"source_size": 50, "source_modified_at": "2026-01-01T10:00:00Z", "status": "skipped_conflict"}
}}
EOF
CONFLICT_MODE=skip
expect_true "candidates selected" select_candidates "$WORK/scope.json" "$WORK/state.json" "$WORK/candidates.json"
expect_eq "new and changed files need work" 'new.3mf|grown.3mf|touched.3mf' "$(paths "$WORK/candidates.json")"
CONFLICT_MODE=overwrite
select_candidates "$WORK/scope.json" "$WORK/state.json" "$WORK/candidates.json"
expect_eq "earlier skip is revisited after a mode change" 'new.3mf|grown.3mf|touched.3mf|conflict.3mf' "$(paths "$WORK/candidates.json")"
printf '{"schema_version":1,"items":{}}' >"$WORK/empty-state.json"
select_candidates "$WORK/scope.json" "$WORK/empty-state.json" "$WORK/candidates.json"
expect_eq "lost state: every non-empty file is re-examined" 5 "$(jq 'length' "$WORK/candidates.json")"

cat >"$WORK/second.json" <<'EOF'
[
  {"path": "new.3mf", "size": 10, "modtime": "2026-01-01T10:00:00Z"},
  {"path": "grown.3mf", "size": 35, "modtime": "2026-01-01T10:00:00Z"},
  {"path": "touched.3mf", "size": 40, "modtime": "2026-01-02T10:00:05Z"}
]
EOF
expect_true "stable files selected" select_stable "$WORK/candidates.json" "$WORK/second.json" "$WORK/stable.json"
expect_eq "only files identical in both samples are stable" 'new.3mf' "$(paths "$WORK/stable.json")"

item=$(build_item 'a b.3mf' 'Folder/a b.3mf' 123 2026-01-01T10:00:00Z abc synced true 2026-01-01T11:00:00Z 123 sha1)
expect_eq "item is managed" true "$(printf '%s' "$item" | jq '.managed_by_service')"
expect_eq "item destination size is numeric" 123 "$(printf '%s' "$item" | jq '.confirmed_destination_size')"
item=$(build_item a.3mf Folder/a.3mf 5 2026-01-01T10:00:00Z abc skipped_conflict false '' '' '')
expect_eq "skipped item has no upload time" null "$(printf '%s' "$item" | jq '.last_uploaded_at')"
expect_eq "skipped item is not managed" false "$(printf '%s' "$item" | jq '.managed_by_service')"

printf 'model-bytes' >"$WORK/staged.3mf"
hash=$(sha256sum "$WORK/staged.3mf" | cut -d' ' -f1)
printf '{"size":11,"modtime":"2026-01-01T10:00:00Z","sha256":"%s","sha1":"x"}' "$hash" >"$WORK/staged.json"
expect_true "staged file reusable" staged_is_current "$WORK/staged.3mf" "$WORK/staged.json" 11 2026-01-01T10:00:00Z
expect_false "staged file of an older source sample" staged_is_current "$WORK/staged.3mf" "$WORK/staged.json" 11 2026-01-02T10:00:00Z
expect_false "staged file with other size" staged_is_current "$WORK/staged.3mf" "$WORK/staged.json" 12 2026-01-01T10:00:00Z
printf 'model-bytez' >"$WORK/staged.3mf"
expect_false "staged file with damaged content" staged_is_current "$WORK/staged.3mf" "$WORK/staged.json" 11 2026-01-01T10:00:00Z

BAMBU_SOURCE_PATH=/
expect_eq "source path at root" 'bambu:/a b.3mf' "$(source_remote_path 'a b.3mf')"
BAMBU_SOURCE_PATH=/models
expect_eq "source path in folder" 'bambu:/models/sub/a.3mf' "$(source_remote_path 'sub/a.3mf')"

# ---------------------------------------------------------------------- staging

STAGING_DIR="$WORK/staging"
mkdir -p "$STAGING_DIR"
RUNTIME_DIR=$WORK
RCLONE_STDERR="$WORK/rclone.stderr"
: >"$RCLONE_STDERR"
CYCLE_UNSTABLE=0
expected_hash=$(printf 'model-bytes' | sha256sum | cut -d' ' -f1)

# Stand-ins for the network: the "download" writes fixed bytes to its destination
# argument, and the answer of the source re-check is chosen per test.
DOWNLOAD_RESULT=0
rclone_run() {
  [ "$DOWNLOAD_RESULT" -eq 0 ] || return "$DOWNLOAD_RESULT"
  printf 'model-bytes' >"$5"
}
RECHECK_RESULT=0
source_still_matches() { return "$RECHECK_RESULT"; }

stage_download a.3mf 11 2026-01-01T10:00:00Z "$STAGING_DIR/a.3mf" "$STAGING_DIR/a.json"
expect_eq "verified download is staged" 0 "$?"
expect_eq "staged hash is recorded" "$expected_hash" "$(jq -r '.sha256' "$STAGING_DIR/a.json")"
expect_true "staged download is reusable" staged_is_current "$STAGING_DIR/a.3mf" "$STAGING_DIR/a.json" 11 2026-01-01T10:00:00Z

RECHECK_RESULT=1
stage_download b.3mf 11 2026-01-01T10:00:00Z "$STAGING_DIR/b.3mf" "$STAGING_DIR/b.json"
expect_eq "source changed during download is not a failure" 3 "$?"
expect_false "changed download is discarded" test -e "$STAGING_DIR/b.3mf"
expect_false "changed download leaves no metadata" test -e "$STAGING_DIR/b.json"
expect_eq "changed download counts as waiting" 1 "$CYCLE_UNSTABLE"

RECHECK_RESULT=2
stage_download c.3mf 11 2026-01-01T10:00:00Z "$STAGING_DIR/c.3mf" "$STAGING_DIR/c.json"
expect_eq "failed source re-check fails the file" 1 "$?"
expect_false "unverifiable download is discarded" test -e "$STAGING_DIR/c.3mf"

RECHECK_RESULT=0
stage_download d.3mf 12 2026-01-01T10:00:00Z "$STAGING_DIR/d.3mf" "$STAGING_DIR/d.json"
expect_eq "truncated download fails the file" 1 "$?"
expect_false "truncated download is discarded" test -e "$STAGING_DIR/d.3mf"

DOWNLOAD_RESULT=5
stage_download e.3mf 11 2026-01-01T10:00:00Z "$STAGING_DIR/e.3mf" "$STAGING_DIR/e.json"
expect_eq "transfer error fails the file" 1 "$?"
expect_false "failed transfer leaves no metadata" test -e "$STAGING_DIR/e.json"

# ----------------------------------------------------------------------- result

printf '%s tests, %s failed\n' "$TESTS" "$FAILURES"
[ "$FAILURES" -eq 0 ]
