# shellcheck shell=sh
# rclone and Nextcloud access. Requires log.sh, process.sh, a loaded configuration and RUNTIME_DIR.

# Configures both rclone remotes through environment variables, which keeps the secrets
# out of process arguments. rclone only accepts passwords in its reversible "obscured"
# form; they are produced via stdin here.
remote_configure() {
  local name bambu_pass nextcloud_pass

  # User supplied RCLONE_* settings could silently change transfer or TLS behaviour
  # (for example RCLONE_NO_CHECK_CERTIFICATE), so they are dropped.
  for name in $(env | sed -n 's/^\(RCLONE_[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$name"
    log warn rclone_env_ignored "variable=$name"
  done

  RCLONE_STDERR="$RUNTIME_DIR/rclone.stderr"
  export RCLONE_CONFIG="$RUNTIME_DIR/rclone.conf"
  : >"$RCLONE_CONFIG"

  bambu_pass=$(printf '%s\n' "$BAMBU_ACCESS_CODE" | rclone obscure - 2>/dev/null)
  nextcloud_pass=$(printf '%s\n' "$NEXTCLOUD_APP_PASSWORD" | rclone obscure - 2>/dev/null)
  if [ -z "$bambu_pass" ] || [ -z "$nextcloud_pass" ]; then
    log error rclone_setup_failed "hint=could not prepare the credentials for rclone"
    return 1
  fi

  # Implicit FTPS (TLS from the first byte), as used by Bambu Lab printers on port 990.
  export RCLONE_CONFIG_BAMBU_TYPE=ftp
  export RCLONE_CONFIG_BAMBU_HOST="$BAMBU_HOST"
  export RCLONE_CONFIG_BAMBU_PORT="$BAMBU_PORT"
  export RCLONE_CONFIG_BAMBU_USER="$BAMBU_USERNAME"
  export RCLONE_CONFIG_BAMBU_PASS="$bambu_pass"
  export RCLONE_CONFIG_BAMBU_TLS=true
  export RCLONE_CONFIG_BAMBU_EXPLICIT_TLS=false
  # Scoped to the printer remote only; Nextcloud certificates are always verified.
  export RCLONE_CONFIG_BAMBU_NO_CHECK_CERTIFICATE="$BAMBU_TLS_INSECURE"

  export RCLONE_CONFIG_NEXTCLOUD_TYPE=webdav
  export RCLONE_CONFIG_NEXTCLOUD_URL="$NEXTCLOUD_WEBDAV_URL"
  export RCLONE_CONFIG_NEXTCLOUD_VENDOR=nextcloud
  export RCLONE_CONFIG_NEXTCLOUD_USER="$NEXTCLOUD_USERNAME"
  export RCLONE_CONFIG_NEXTCLOUD_PASS="$nextcloud_pass"
}

# rclone_run STDOUT_FILE RETRIES ARGS...
rclone_run() {
  local out="$1" retries="$2" rc
  shift 2
  run_child rclone "$@" --retries "$retries" --retries-sleep 5s --low-level-retries 5 \
    --contimeout 30s --timeout 5m --stats 0 --transfers 1 --checkers 1 --log-level NOTICE \
    >"$out" 2>"$RCLONE_STDERR"
  rc=$?
  [ "$rc" -eq 0 ] || log debug rclone_failed "command=$1" "exit_code=$rc" "detail=$(rclone_error)"
  return "$rc"
}

# Same as rclone_run, for commands that talk to Nextcloud: adds the optional private CA.
rclone_nextcloud() {
  if [ -n "$NEXTCLOUD_CA_CERT_FILE" ]; then
    rclone_run "$@" --ca-cert "$NEXTCLOUD_CA_CERT_FILE"
  else
    rclone_run "$@"
  fi
}

# Last lines of the most recent rclone error output, for log messages.
rclone_error() {
  [ -s "$RCLONE_STDERR" ] || return 0
  tail -n 3 "$RCLONE_STDERR" | cut -c1-400
}

source_remote_path() {
  if [ "$BAMBU_SOURCE_PATH" = / ]; then
    printf 'bambu:/%s' "$1"
  else
    printf 'bambu:%s/%s' "$BAMBU_SOURCE_PATH" "$1"
  fi
}

# Writes the complete in-scope source inventory to FILE as a sorted JSON array of
# {path, size, modtime}. Fails on any listing error or malformed output; a successful
# empty listing yields [].
list_source() {
  local out="$1" raw="$RUNTIME_DIR/list.raw"
  if [ "$SCAN_MODE" = recursive ]; then
    rclone_run "$raw" 1 lsjson "bambu:$BAMBU_SOURCE_PATH" --files-only --no-mimetype \
      --include '*.3mf' --ignore-case --recursive || return 1
  else
    rclone_run "$raw" 1 lsjson "bambu:$BAMBU_SOURCE_PATH" --files-only --no-mimetype \
      --include '*.3mf' --ignore-case || return 1
  fi
  jq 'if type != "array" then error("listing is not an array") else
        [ .[] | select(.IsDir | not) | {path: .Path, size: .Size, modtime: .ModTime} ] | sort_by(.path)
      end' "$raw" >"$out" 2>/dev/null
}

# The functions below report through globals instead of stdout: a command substitution
# would run rclone in a subshell, where a stop signal could not interrupt it.

# dest_stat DEST_PATH -> sets DEST_SIZE and DEST_SHA1 (empty when Nextcloud has no checksum).
# Returns 0 = file exists, 1 = confirmed absent, 2 = unknown (error or not a regular file).
dest_stat() {
  local out="$RUNTIME_DIR/dest_stat.json"
  DEST_SIZE=
  DEST_SHA1=
  rclone_nextcloud "$out" 1 lsjson --stat --hash --hash-type sha1 --no-mimetype "nextcloud:$1"
  case "$?" in
    0)
      jq -e 'type == "object" and (.IsDir | not) and (.Size | type) == "number" and .Size >= 0' \
        "$out" >/dev/null 2>&1 || return 2
      DEST_SIZE=$(jq -r '.Size' "$out")
      DEST_SHA1=$(jq -r '.Hashes.sha1 // ""' "$out")
      ;;
    3 | 4) return 1 ;;
    *) return 2 ;;
  esac
}

# dest_sha256 DEST_PATH -> downloads the destination file and sets DEST_SHA256.
dest_sha256() {
  local out="$RUNTIME_DIR/dest_hash.txt"
  DEST_SHA256=
  rclone_nextcloud "$out" 1 hashsum sha256 --download "nextcloud:$1" || return 1
  DEST_SHA256=$(head -n 1 "$out" | cut -c1-64)
  case "$DEST_SHA256" in '' | *[!0-9a-f]*) return 1 ;; esac
  [ "${#DEST_SHA256}" -eq 64 ]
}

# Asks Nextcloud whether the Versions app (files_versions) is active for this account and
# sets NC_VERSIONING to enabled, disabled or unknown.
nextcloud_versioning_status() {
  local body="$RUNTIME_DIR/capabilities.json" header="$RUNTIME_DIR/auth.header" rc
  NC_VERSIONING=unknown
  # The credentials travel in a private, short-lived file rather than in process arguments.
  printf 'Authorization: Basic %s\n' \
    "$(printf '%s:%s' "$NEXTCLOUD_USERNAME" "$NEXTCLOUD_APP_PASSWORD" | base64 | tr -d '\n')" >"$header"
  run_child curl --silent --show-error --fail --max-time 30 \
    --header @"$header" --header 'OCS-APIRequest: true' --header 'Accept: application/json' \
    ${NEXTCLOUD_CA_CERT_FILE:+--cacert "$NEXTCLOUD_CA_CERT_FILE"} \
    --output "$body" "$NEXTCLOUD_BASE_URL/ocs/v2.php/cloud/capabilities?format=json" \
    2>"$RCLONE_STDERR"
  rc=$?
  rm -f "$header"
  if [ "$rc" -ne 0 ]; then
    log debug capabilities_request_failed "detail=$(rclone_error)"
    return 0
  fi
  NC_VERSIONING=$(jq -r 'if (.ocs.data.capabilities.files | type) != "object" then "unknown"
      elif .ocs.data.capabilities.files.versioning == true then "enabled"
      else "disabled" end' "$body" 2>/dev/null) || NC_VERSIONING=unknown
  [ -n "$NC_VERSIONING" ] || NC_VERSIONING=unknown
}
