# shellcheck shell=sh
# One synchronisation cycle: discover -> wait for stability -> stage -> upload -> verify -> checkpoint.
# Requires log.sh, process.sh, state.sh, remote.sh and a loaded configuration.

JQ_UNSAFE_PATH='def unsafe_path:
  length == 0 or startswith("/") or endswith("/")
  or any(explode[]; . < 32 or . == 127 or . == 92)
  or any(split("/")[]; . == "" or . == "." or . == "..");'

# split_listing LISTING IN_SCOPE_OUT IGNORED_OUT
# Only .3mf files with safe relative names are in scope; in root mode nothing nested is.
split_listing() {
  # shellcheck disable=SC2016  # $scan_mode is a jq variable
  local in_scope='(.path | unsafe_path | not)
    and (.path | ascii_downcase | endswith(".3mf"))
    and ($scan_mode == "recursive" or (.path | contains("/") | not))'
  jq --arg scan_mode "$SCAN_MODE" "$JQ_UNSAFE_PATH [ .[] | select($in_scope) ]" "$1" >"$2" &&
    jq --arg scan_mode "$SCAN_MODE" "$JQ_UNSAFE_PATH [ .[] | select($in_scope | not) ]" "$1" >"$3"
}

# select_candidates IN_SCOPE STATE_SNAPSHOT OUT
# A file needs work when it is new, when its listed size or time differs from the last
# checkpoint, or when an earlier conflict skip no longer matches the configured mode.
select_candidates() {
  jq --slurpfile state "$2" --arg conflict_mode "$CONFLICT_MODE" '
    $state[0].items as $items
    | [ .[] | select(.size > 0) | . as $file | ($items[$file.path] // null) as $known
        | select($known == null
            or $known.source_size != $file.size
            or $known.source_modified_at != $file.modtime
            or ($known.status == "skipped_conflict" and $conflict_mode != "skip")) ]' "$1" >"$3"
}

# select_stable CANDIDATES SECOND_LISTING OUT
select_stable() {
  jq --slurpfile second "$2" '
    INDEX($second[0][]; .path) as $again
    | [ .[] | select(($again[.path] // null) as $now
        | $now != null and $now.size == .size and $now.modtime == .modtime) ]' "$1" >"$3"
}

# Returns 0 = unchanged, 1 = changed or gone, 2 = could not check.
source_still_matches() {
  local listing="$RUNTIME_DIR/list_recheck.json"
  list_source "$listing" || return 2
  jq -e --arg path "$1" --argjson size "$2" --arg modtime "$3" \
    'any(.[]; .path == $path and .size == $size and .modtime == $modtime)' "$listing" >/dev/null 2>&1
}

staging_has_space() {
  local needed_kb=$(($1 / 1024 + 65536)) available_kb
  available_kb=$(df -Pk "$STAGING_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')
  is_uint "$available_kb" || return 0
  [ "$available_kb" -ge "$needed_kb" ]
}

# A staged file is reusable only if it still describes the current source sample and its
# bytes still match the hash recorded when it was downloaded.
staged_is_current() {
  local staged="$1" meta="$2" size="$3" modtime="$4"
  [ -f "$staged" ] && [ -f "$meta" ] || return 1
  jq -e --argjson size "$size" --arg modtime "$modtime" \
    '.size == $size and .modtime == $modtime and (.sha256 | type) == "string" and (.sha1 | type) == "string"' \
    "$meta" >/dev/null 2>&1 || return 1
  [ "$(stat -c %s "$staged" 2>/dev/null)" = "$size" ] || return 1
  [ "$(sha256sum "$staged" | cut -d' ' -f1)" = "$(jq -r '.sha256' "$meta")" ]
}

# stage_download PATH SIZE MODTIME STAGED META
# Returns 0 = staged, 1 = failed, 3 = source changed while downloading (retried next cycle).
stage_download() {
  local path="$1" size="$2" modtime="$3" staged="$4" meta="$5" sha256 sha1
  if ! staging_has_space "$size"; then
    log error staging_disk_full "file=$path" "bytes=$size" "hint=free space in $DATA_DIR"
    return 1
  fi
  if ! rclone_run /dev/null 3 copyto "$(source_remote_path "$path")" "$staged" --ignore-times; then
    log error download_failed "file=$path" "detail=$(rclone_error)"
    rm -f "$staged" "$staged".*.partial
    return 1
  fi
  if [ "$(stat -c %s "$staged" 2>/dev/null)" != "$size" ]; then
    log warn download_incomplete "file=$path" "expected_bytes=$size"
    rm -f "$staged"
    return 1
  fi
  source_still_matches "$path" "$size" "$modtime"
  case "$?" in
    0) ;;
    1)
      log info source_changed_during_download "file=$path"
      rm -f "$staged"
      CYCLE_UNSTABLE=$((CYCLE_UNSTABLE + 1))
      return 3
      ;;
    *)
      log error source_recheck_failed "file=$path" "detail=$(rclone_error)"
      rm -f "$staged"
      return 1
      ;;
  esac
  sha256=$(sha256sum "$staged" | cut -d' ' -f1)
  sha1=$(sha1sum "$staged" | cut -d' ' -f1)
  if ! jq -n --argjson size "$size" --arg modtime "$modtime" --arg sha256 "$sha256" --arg sha1 "$sha1" \
    '{size: $size, modtime: $modtime, sha256: $sha256, sha1: $sha1}' >"$meta.tmp" || ! mv -f "$meta.tmp" "$meta"; then
    log error staging_write_failed "file=$path"
    rm -f "$staged" "$meta.tmp"
    return 1
  fi
  log info downloaded "file=$path" "bytes=$size" "sha256=$sha256"
}

# build_item PATH DEST SIZE MODTIME SHA256 STATUS MANAGED UPLOADED_AT DEST_SIZE VERIFICATION
build_item() {
  jq -cn --arg source_path "$1" --arg destination_path "$2" --argjson size "$3" --arg modtime "$4" \
    --arg sha256 "$5" --arg status "$6" --argjson managed "$7" --arg uploaded_at "$8" \
    --arg destination_size "$9" --arg verification "${10}" '
    def blank_to_null: if . == "" then null else . end;
    {
      source_path: $source_path,
      destination_path: $destination_path,
      source_size: $size,
      source_modified_at: $modtime,
      sha256: $sha256,
      status: $status,
      managed_by_service: $managed,
      last_uploaded_at: ($uploaded_at | blank_to_null),
      confirmed_destination_size: ($destination_size | blank_to_null | if . == null then null else tonumber end),
      destination_verification: ($verification | blank_to_null)
    }'
}

# checkpoint PATH ITEM_JSON -> persists the item; the staged file is only released afterwards.
checkpoint() {
  if ! state_put "$1" "$2"; then
    log error state_write_failed "file=$1" "hint=the staged copy is kept and the destination is re-checked next cycle"
    return 1
  fi
}

process_file() {
  local path="$1" size="$2" modtime="$3"
  local dest="$NEXTCLOUD_FOLDER/$1" key staged meta sha256 sha1 known managed=false action verification same

  if [ "$DRY_RUN" = true ]; then
    dest_stat "$dest"
    case "$?" in
      0) log info dry_run_would_compare "file=$path" "destination=$dest" "conflict_mode=$CONFLICT_MODE" ;;
      1) log info dry_run_would_upload "file=$path" "destination=$dest" ;;
      *)
        log error destination_check_failed "file=$path" "detail=$(rclone_error)"
        return 1
        ;;
    esac
    CYCLE_PLANNED=$((CYCLE_PLANNED + 1))
    return 0
  fi

  key=$(printf '%s' "$path" | sha256sum | cut -c1-32)
  staged="$STAGING_DIR/$key.3mf"
  meta="$STAGING_DIR/$key.json"

  if staged_is_current "$staged" "$meta" "$size" "$modtime"; then
    log info staged_file_reused "file=$path"
  else
    rm -f "$staged" "$meta"
    stage_download "$path" "$size" "$modtime" "$staged" "$meta"
    case "$?" in
      0) ;;
      3) return 0 ;;
      *) return 1 ;;
    esac
  fi
  sha256=$(jq -r '.sha256' "$meta")
  sha1=$(jq -r '.sha1' "$meta")

  known=$(state_get "$path")
  if [ -n "$known" ]; then
    managed=$(printf '%s' "$known" | jq -r '.managed_by_service == true')
    if [ "$(printf '%s' "$known" | jq -r '.status')" = synced ] &&
      [ "$(printf '%s' "$known" | jq -r '.sha256')" = "$sha256" ]; then
      # Only the listing metadata changed. Uploading again would create a needless version.
      checkpoint "$path" "$(printf '%s' "$known" | jq -c --argjson size "$size" --arg modtime "$modtime" \
        '.source_size = $size | .source_modified_at = $modtime')" || return 1
      rm -f "$staged" "$meta"
      log info content_unchanged "file=$path"
      CYCLE_UNCHANGED=$((CYCLE_UNCHANGED + 1))
      return 0
    fi
  fi

  dest_stat "$dest"
  case "$?" in
    1) action=upload ;;
    0)
      # Prove whether the destination already holds exactly these bytes. Size alone is
      # not proof, so fall back to hashing the destination when it reports no checksum.
      if [ "$DEST_SIZE" != "$size" ]; then
        same=false
      elif [ -n "$DEST_SHA1" ]; then
        verification=sha1
        [ "$DEST_SHA1" = "$sha1" ] && same=true || same=false
      else
        verification=sha256
        if ! dest_sha256 "$dest"; then
          log error destination_check_failed "file=$path" "detail=$(rclone_error)"
          return 1
        fi
        [ "$DEST_SHA256" = "$sha256" ] && same=true || same=false
      fi

      if [ "$same" = true ]; then
        # Covers a crash between upload and checkpoint, and a lost manifest.
        checkpoint "$path" "$(build_item "$path" "$dest" "$size" "$modtime" "$sha256" synced "$managed" \
          '' "$DEST_SIZE" "$verification")" || return 1
        rm -f "$staged" "$meta"
        log info destination_already_current "file=$path" "destination=$dest" "verified_by=$verification"
        CYCLE_UNCHANGED=$((CYCLE_UNCHANGED + 1))
        return 0
      fi

      case "$CONFLICT_MODE" in
        skip)
          checkpoint "$path" "$(build_item "$path" "$dest" "$size" "$modtime" "$sha256" skipped_conflict \
            "$managed" '' '' '')" || return 1
          rm -f "$staged" "$meta"
          log warn conflict_skipped "file=$path" "destination=$dest" \
            "reason=destination exists with different content and CONFLICT_MODE=skip"
          CYCLE_SKIPPED=$((CYCLE_SKIPPED + 1))
          return 0
          ;;
        overwrite) action=overwrite ;;
        *)
          [ -n "$NC_VERSIONING" ] || nextcloud_versioning_status
          if [ "$NC_VERSIONING" != enabled ]; then
            log error version_guard_blocked "file=$path" "destination=$dest" "nextcloud_versioning=$NC_VERSIONING" \
              "hint=the existing file was not overwritten; enable the Nextcloud Versions app or choose another CONFLICT_MODE"
            return 1
          fi
          action=version
          ;;
      esac
      ;;
    *)
      log error destination_check_failed "file=$path" "detail=$(rclone_error)"
      return 1
      ;;
  esac

  # --inplace sends one PUT to the final path, which is what Nextcloud versions.
  # No rclone-level retry: after an unclear failure the next cycle compares the
  # destination by content instead of uploading the same bytes twice.
  if ! rclone_nextcloud /dev/null 1 copyto "$staged" "nextcloud:$dest" --ignore-times --inplace; then
    log error upload_failed "file=$path" "destination=$dest" "detail=$(rclone_error)"
    return 1
  fi

  if ! dest_stat "$dest" || [ "$DEST_SIZE" != "$size" ] || { [ -n "$DEST_SHA1" ] && [ "$DEST_SHA1" != "$sha1" ]; }; then
    log error upload_verification_failed "file=$path" "destination=$dest" "expected_bytes=$size" "found_bytes=$DEST_SIZE"
    return 1
  fi
  if [ -n "$DEST_SHA1" ]; then
    verification=sha1
  else
    verification=size
    log warn upload_verified_by_size_only "file=$path" "reason=Nextcloud returned no checksum"
  fi

  checkpoint "$path" "$(build_item "$path" "$dest" "$size" "$modtime" "$sha256" synced true \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DEST_SIZE" "$verification")" || return 1
  rm -f "$staged" "$meta"

  case "$action" in
    upload)
      log info uploaded "file=$path" "destination=$dest" "bytes=$size" "verified_by=$verification"
      CYCLE_UPLOADED=$((CYCLE_UPLOADED + 1))
      ;;
    version)
      log info version_updated "file=$path" "destination=$dest" "bytes=$size" "verified_by=$verification"
      CYCLE_UPDATED=$((CYCLE_UPDATED + 1))
      ;;
    *)
      log info overwritten "file=$path" "destination=$dest" "bytes=$size" "verified_by=$verification"
      CYCLE_UPDATED=$((CYCLE_UPDATED + 1))
      ;;
  esac
}

# log_paths LEVEL EVENT FILE [key=value ...] -> one log line per listed path.
log_paths() {
  local level="$1" event="$2" file="$3" count index=0
  shift 3
  count=$(jq 'length' "$file")
  while [ "$index" -lt "$count" ]; do
    log "$level" "$event" "file=$(jq -r ".[$index].path" "$file")" "$@"
    index=$((index + 1))
  done
}

cycle_summary() {
  log "$1" cycle_complete "result=$2" "scanned=$3" "uploaded=$CYCLE_UPLOADED" "updated=$CYCLE_UPDATED" \
    "unchanged=$CYCLE_UNCHANGED" "skipped=$CYCLE_SKIPPED" "waiting=$CYCLE_UNSTABLE" "failed=$CYCLE_FAILED" \
    "dry_run_planned=$CYCLE_PLANNED" "seconds=$(($(date +%s) - $4))"
}

# Returns 0 when the cycle finished without errors.
run_cycle() {
  local started first="$RUNTIME_DIR/list_first.json" second="$RUNTIME_DIR/list_second.json"
  local in_scope="$RUNTIME_DIR/in_scope.json" ignored="$RUNTIME_DIR/ignored.json"
  local snapshot="$RUNTIME_DIR/state_snapshot.json" candidates="$RUNTIME_DIR/candidates.json"
  local stable="$RUNTIME_DIR/stable.json" unstable="$RUNTIME_DIR/unstable.json"
  local scanned count index=0 path size modtime
  started=$(date +%s)
  NC_VERSIONING=
  CYCLE_UPLOADED=0
  CYCLE_UPDATED=0
  CYCLE_UNCHANGED=0
  CYCLE_SKIPPED=0
  CYCLE_UNSTABLE=0
  CYCLE_FAILED=0
  CYCLE_PLANNED=0

  if ! list_source "$first"; then
    log error source_listing_failed "printer=$BAMBU_HOST:$BAMBU_PORT" "detail=$(rclone_error)" \
      "result=nothing was changed; retrying next cycle"
    case "$(rclone_error)" in
      *x509* | *certificate*)
        log error printer_certificate_untrusted \
          "hint=Bambu printers present a self-signed certificate; set BAMBU_TLS_INSECURE=true to accept it for the printer connection only, on a trusted network"
        ;;
    esac
    return 1
  fi
  if ! split_listing "$first" "$in_scope" "$ignored" || ! state_read >"$snapshot" ||
    ! select_candidates "$in_scope" "$snapshot" "$candidates"; then
    log error cycle_preparation_failed "result=nothing was changed; retrying next cycle"
    return 1
  fi
  log_paths warn source_file_ignored "$ignored" "reason=unsafe or out-of-scope name"
  scanned=$(jq 'length' "$in_scope")
  count=$(jq 'length' "$candidates")
  log debug scan_complete "files=$scanned" "needing_work=$count" "scan_mode=$SCAN_MODE"

  if [ "$count" -eq 0 ]; then
    cycle_summary info ok "$scanned" "$started"
    return 0
  fi

  # A second complete listing after a pause: files still being written are left alone.
  interruptible_sleep "$STABILITY_CHECK_INTERVAL"
  [ "$STOP" = 0 ] || return 0
  if ! list_source "$second" || ! select_stable "$candidates" "$second" "$stable" ||
    ! jq --slurpfile stable "$stable" '. - $stable[0]' "$candidates" >"$unstable"; then
    log error source_listing_failed "printer=$BAMBU_HOST:$BAMBU_PORT" "detail=$(rclone_error)" \
      "result=nothing was changed; retrying next cycle"
    return 1
  fi
  CYCLE_UNSTABLE=$(jq 'length' "$unstable")
  log_paths info source_file_not_stable "$unstable" "result=waiting until size and time stop changing"

  count=$(jq 'length' "$stable")
  while [ "$index" -lt "$count" ] && [ "$STOP" = 0 ]; do
    path=$(jq -r ".[$index].path" "$stable")
    size=$(jq -r ".[$index].size" "$stable")
    modtime=$(jq -r ".[$index].modtime" "$stable")
    process_file "$path" "$size" "$modtime" || CYCLE_FAILED=$((CYCLE_FAILED + 1))
    index=$((index + 1))
  done

  if [ "$CYCLE_FAILED" -ne 0 ]; then
    cycle_summary warn failed "$scanned" "$started"
    return 1
  fi
  cycle_summary info ok "$scanned" "$started"
}
