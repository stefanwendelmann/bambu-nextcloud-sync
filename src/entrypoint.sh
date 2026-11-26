#!/bin/sh
# Bambu Nextcloud Sync
# One-way sync of .3mf project files from a Bambu Lab printer (implicit FTPS) to a
# Nextcloud folder (WebDAV). The printer is only ever listed and read.
set -u
umask 077

APP_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=src/log.sh
. "$APP_DIR/log.sh"
# shellcheck source=src/process.sh
. "$APP_DIR/process.sh"
# shellcheck source=src/config.sh
. "$APP_DIR/config.sh"
# shellcheck source=src/state.sh
. "$APP_DIR/state.sh"
# shellcheck source=src/remote.sh
. "$APP_DIR/remote.sh"
# shellcheck source=src/sync.sh
. "$APP_DIR/sync.sh"

RUNTIME_DIR=

cleanup() {
  [ -z "$RUNTIME_DIR" ] || rm -rf "$RUNTIME_DIR"
}

main() {
  local check_only=false result

  case "${1:-}" in
    '') ;;
    --check-config) check_only=true ;;
    *)
      echo "Usage: entrypoint.sh [--check-config]" >&2
      exit 64
      ;;
  esac

  config_load || exit 2
  if [ "$check_only" = true ]; then
    log info config_valid
    exit 0
  fi

  RUNTIME_DIR=$(mktemp -d /tmp/bambu-nextcloud-sync.XXXXXX) || exit 1
  trap cleanup EXIT
  trap on_stop_signal TERM INT

  state_init || exit 1
  state_lock || exit 1
  remote_configure || exit 1

  log info service_started "printer=$BAMBU_HOST:$BAMBU_PORT" "source_path=$BAMBU_SOURCE_PATH" \
    "nextcloud=$NEXTCLOUD_BASE_URL" "folder=$NEXTCLOUD_FOLDER" "scan_mode=$SCAN_MODE" "sync_mode=$SYNC_MODE" \
    "conflict_mode=$CONFLICT_MODE" "interval_seconds=$SYNC_INTERVAL" "dry_run=$DRY_RUN"
  [ "$BAMBU_TLS_INSECURE" = false ] || log warn printer_certificate_not_verified \
    "scope=printer connection only; Nextcloud certificates are still verified"
  [ "$NEXTCLOUD_PLAIN_HTTP" = false ] || log warn nextcloud_without_tls \
    "hint=the app password is sent unencrypted; use https:// outside a private container network"
  [ "$DRY_RUN" = false ] || log info dry_run_active "result=nothing is downloaded, uploaded or recorded"

  while :; do
    run_cycle
    result=$?
    [ "$RUN_ONCE" = false ] || exit "$result"
    [ "$STOP" = 0 ] || break
    interruptible_sleep "$SYNC_INTERVAL"
    [ "$STOP" = 0 ] || break
  done
  log info service_stopped
}

main "$@"
