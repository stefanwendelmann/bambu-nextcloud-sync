# shellcheck shell=sh
# Durable state: an atomically replaced JSON manifest plus the download staging area.
# Requires log.sh and a validated DATA_DIR.

STATE_SCHEMA_VERSION=1

state_init() {
  STATE_DIR="$DATA_DIR/state"
  STAGING_DIR="$DATA_DIR/staging"
  STATE_FILE="$STATE_DIR/manifest.json"
  # The manifest only describes one destination: this WebDAV account and folder.
  STATE_DESTINATION="$NEXTCLOUD_WEBDAV_URL$NEXTCLOUD_FOLDER"
  if ! mkdir -p "$STATE_DIR" "$STAGING_DIR" 2>/dev/null || ! (: >"$STATE_DIR/.write-test") 2>/dev/null; then
    log error data_dir_unwritable "path=$DATA_DIR" "hint=mount a writable volume at $DATA_DIR"
    return 1
  fi
  rm -f "$STATE_DIR/.write-test"
  state_validate || return 1
  staging_cleanup
}

# state_set_aside REASON -> stops using the current manifest and sets STATE_ASIDE.
# The file is renamed, except in a dry run, which must not change anything.
state_set_aside() {
  if [ "$DRY_RUN" = true ]; then
    STATE_ASIDE="$STATE_FILE (left in place: dry run)"
    STATE_FILE="$STATE_DIR/manifest.unused-in-dry-run.json"
    return 0
  fi
  STATE_ASIDE="$STATE_FILE.$1-$(date -u +%Y%m%dT%H%M%SZ)"
  if ! mv "$STATE_FILE" "$STATE_ASIDE"; then
    log error state_set_aside_failed "path=$STATE_FILE"
    return 1
  fi
}

# A manifest that is unreadable, or that belongs to another destination, is set aside and
# the service continues with an empty one. That is the conservative choice: nothing is
# treated as synced or managed, and existing destination files are re-identified by
# content instead of being uploaded again.
state_validate() {
  local version
  [ -e "$STATE_FILE" ] || return 0
  if version=$(jq -r 'if type == "object" and (.items | type) == "object" and (.schema_version | type) == "number"
      then .schema_version else error("invalid manifest") end' "$STATE_FILE" 2>/dev/null); then
    if [ "$version" != "$STATE_SCHEMA_VERSION" ]; then
      log error state_schema_unsupported "found=$version" "supported=$STATE_SCHEMA_VERSION" \
        "hint=this manifest was written by a different version; it was left untouched"
      return 1
    fi
    [ "$(jq -r '.destination // ""' "$STATE_FILE")" != "$STATE_DESTINATION" ] || return 0
    state_set_aside other-destination || return 1
    log warn state_destination_changed "moved_to=$STATE_ASIDE" \
      "result=the new destination is examined by content; nothing is assumed to be synced"
    return 0
  fi
  state_set_aside corrupt || return 1
  log error state_corrupt_quarantined "moved_to=$STATE_ASIDE"
}

# Removes interrupted downloads and staged files that lost their metadata sidecar.
staging_cleanup() {
  local file
  for file in "$STAGING_DIR"/*; do
    [ -e "$file" ] || continue
    case "$file" in
      *.partial | *.tmp) rm -f "$file" ;;
      *.3mf) [ -f "${file%.3mf}.json" ] || rm -f "$file" ;;
      *.json) [ -f "${file%.json}.3mf" ] || rm -f "$file" ;;
    esac
  done
}

# Holds an exclusive lock for the lifetime of the process. The kernel releases it when the
# process ends, so there are no stale locks to clean up.
state_lock() {
  exec 9>"$STATE_DIR/.lock"
  if ! flock -n 9; then
    log error already_running "hint=another instance is using $DATA_DIR; run exactly one instance per data volume"
    return 1
  fi
}

state_read() {
  if [ -s "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    jq -n --argjson version "$STATE_SCHEMA_VERSION" --arg destination "$STATE_DESTINATION" \
      '{schema_version: $version, destination: $destination, items: {}}'
  fi
}

# state_get SOURCE_PATH -> prints the item as compact JSON, or nothing.
state_get() {
  state_read | jq -c --arg path "$1" '.items[$path] // empty'
}

# state_put SOURCE_PATH ITEM_JSON -> write-then-rename, validated before it replaces the manifest.
state_put() {
  local tmp="$STATE_FILE.$$.tmp"
  if state_read | jq --arg path "$1" --argjson item "$2" '.items[$path] = $item' >"$tmp" 2>/dev/null &&
    jq -e --argjson version "$STATE_SCHEMA_VERSION" \
      '.schema_version == $version and (.items | type) == "object"' "$tmp" >/dev/null 2>&1; then
    sync -d "$tmp" 2>/dev/null || true
    if mv -f "$tmp" "$STATE_FILE"; then
      return 0
    fi
  fi
  rm -f "$tmp"
  return 1
}
