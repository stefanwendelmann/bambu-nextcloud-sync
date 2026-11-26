# shellcheck shell=sh
# Configuration loading and validation. Requires log.sh.

CONFIG_ERRORS=0

config_fail() {
  CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
  log error config_invalid "problem=$1"
}

has_control_chars() {
  [ "$(printf '%s' "$1" | tr -d '\000-\037\177' | wc -c)" -ne "$(printf '%s' "$1" | wc -c)" ]
}

is_uint() {
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 9 ]
}

has_dot_component() {
  case "/$1/" in */./* | */../*) return 0 ;; esac
  return 1
}

# config_string NAME DEFAULT REQUIRED(true|false)
config_string() {
  local name="$1" default="$2" required="$3" value
  eval "value=\${$name:-}"
  [ -n "$value" ] || value=$default
  if [ -z "$value" ]; then
    [ "$required" = false ] || config_fail "$name is required"
  elif has_control_chars "$value"; then
    config_fail "$name must not contain control characters"
    value=
  else
    case "$value" in
      REPLACE_*)
        config_fail "$name still contains the placeholder from .env.example"
        value=
        ;;
    esac
  fi
  eval "$name=\$value"
}

# config_enum NAME DEFAULT ALLOWED...
config_enum() {
  local name="$1" default="$2" value option found=false
  shift 2
  eval "value=\${$name:-}"
  [ -n "$value" ] || value=$default
  for option in "$@"; do
    [ "$value" != "$option" ] || found=true
  done
  if [ "$found" = false ]; then
    config_fail "$name must be one of: $*"
    value=$default
  fi
  eval "$name=\$value"
}

# config_uint NAME DEFAULT MIN MAX
config_uint() {
  local name="$1" default="$2" min="$3" max="$4" value
  eval "value=\${$name:-}"
  [ -n "$value" ] || value=$default
  if ! is_uint "$value" || [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
    config_fail "$name must be a whole number between $min and $max"
    value=$default
  fi
  eval "$name=\$value"
}

config_source_path() {
  config_string BAMBU_SOURCE_PATH / true
  case "$BAMBU_SOURCE_PATH" in
    /*) ;;
    *) config_fail "BAMBU_SOURCE_PATH must be an absolute printer path such as /" ;;
  esac
  case "$BAMBU_SOURCE_PATH" in
    *//*) config_fail "BAMBU_SOURCE_PATH must not contain empty path segments" ;;
  esac
  if has_dot_component "$BAMBU_SOURCE_PATH"; then
    config_fail "BAMBU_SOURCE_PATH must not contain . or .. path segments"
  fi
  while [ "$BAMBU_SOURCE_PATH" != / ] && [ "${BAMBU_SOURCE_PATH%/}" != "$BAMBU_SOURCE_PATH" ]; do
    BAMBU_SOURCE_PATH=${BAMBU_SOURCE_PATH%/}
  done
}

config_nextcloud_folder() {
  config_string NEXTCLOUD_FOLDER '3D Druck/Bambu P2S/Projekte' true
  while [ "${NEXTCLOUD_FOLDER#/}" != "$NEXTCLOUD_FOLDER" ]; do
    NEXTCLOUD_FOLDER=${NEXTCLOUD_FOLDER#/}
  done
  while [ "${NEXTCLOUD_FOLDER%/}" != "$NEXTCLOUD_FOLDER" ]; do
    NEXTCLOUD_FOLDER=${NEXTCLOUD_FOLDER%/}
  done
  if [ -z "$NEXTCLOUD_FOLDER" ]; then
    config_fail "NEXTCLOUD_FOLDER must name a dedicated sub folder; the WebDAV account root is not allowed"
    return
  fi
  case "$NEXTCLOUD_FOLDER" in
    *//*) config_fail "NEXTCLOUD_FOLDER must not contain empty path segments" ;;
  esac
  case "$NEXTCLOUD_FOLDER" in
    *\\*) config_fail "NEXTCLOUD_FOLDER must use / as separator and must not contain backslashes" ;;
  esac
  if has_dot_component "$NEXTCLOUD_FOLDER"; then
    config_fail "NEXTCLOUD_FOLDER must not contain . or .. path segments"
  fi
}

# Accepts only the per-user WebDAV endpoint and derives the server base URL from it.
config_nextcloud_url() {
  local marker=/remote.php/dav/files/ url authority user
  NEXTCLOUD_BASE_URL=
  NEXTCLOUD_PLAIN_HTTP=false
  config_string NEXTCLOUD_WEBDAV_URL '' true
  url=$NEXTCLOUD_WEBDAV_URL
  [ -n "$url" ] || return
  case "$url" in
    https://?*) ;;
    http://?*) NEXTCLOUD_PLAIN_HTTP=true ;;
    *)
      config_fail "NEXTCLOUD_WEBDAV_URL must start with https:// (or http:// inside a trusted network)"
      return
      ;;
  esac
  case "$url" in
    *[\ \?\#]*)
      config_fail "NEXTCLOUD_WEBDAV_URL must not contain spaces, query strings or fragments"
      return
      ;;
  esac
  authority=${url#*://}
  authority=${authority%%/*}
  case "$authority" in
    '' | *@*)
      config_fail "NEXTCLOUD_WEBDAV_URL must contain a host name and no embedded credentials"
      return
      ;;
  esac
  case "$url" in
    *"$marker"*) ;;
    *)
      config_fail "NEXTCLOUD_WEBDAV_URL must be the WebDAV address ending in /remote.php/dav/files/USERNAME/, not the browser address"
      return
      ;;
  esac
  user=${url#*"$marker"}
  user=${user%/}
  case "$user" in
    '' | */*)
      config_fail "NEXTCLOUD_WEBDAV_URL must end right after the user name; put sub folders into NEXTCLOUD_FOLDER"
      return
      ;;
  esac
  NEXTCLOUD_BASE_URL=${url%%"$marker"*}
  NEXTCLOUD_WEBDAV_URL="$NEXTCLOUD_BASE_URL$marker$user/"
}

config_load() {
  CONFIG_ERRORS=0

  config_enum LOG_LEVEL info error warn info debug
  LOG_LEVEL_NUM=$(log_level_to_num "$LOG_LEVEL")

  config_string BAMBU_HOST '' true
  case "$BAMBU_HOST" in
    *[!A-Za-z0-9._:-]*)
      config_fail "BAMBU_HOST must be a host name or IP address without scheme, port or path"
      ;;
  esac
  config_uint BAMBU_PORT 990 1 65535
  config_string BAMBU_USERNAME bblp true
  config_string BAMBU_ACCESS_CODE '' true
  config_source_path
  config_enum BAMBU_TLS_INSECURE false true false

  config_nextcloud_url
  config_string NEXTCLOUD_USERNAME '' true
  config_string NEXTCLOUD_APP_PASSWORD '' true
  config_nextcloud_folder
  config_string NEXTCLOUD_CA_CERT_FILE '' false
  if [ -n "$NEXTCLOUD_CA_CERT_FILE" ] && { [ ! -f "$NEXTCLOUD_CA_CERT_FILE" ] || [ ! -r "$NEXTCLOUD_CA_CERT_FILE" ]; }; then
    config_fail "NEXTCLOUD_CA_CERT_FILE must point to a readable PEM file inside the container"
  fi

  config_enum SCAN_MODE root root recursive
  config_enum SYNC_MODE archive archive mirror
  config_enum MIRROR_MODE managed managed exact
  config_enum CONFLICT_MODE version version overwrite skip
  config_enum EXTRACT_METADATA false true false
  config_enum DRY_RUN false true false
  config_enum RUN_ONCE false true false
  config_enum ALLOW_EMPTY_SOURCE_MIRROR false true false
  config_uint SYNC_INTERVAL 300 1 999999999
  config_uint STABILITY_CHECK_INTERVAL 30 1 3600
  config_uint MAX_DELETE_COUNT 10 0 999999999
  config_uint MAX_DELETE_PERCENT 20 0 100

  config_string DATA_DIR /data true
  case "$DATA_DIR" in
    /?*) ;;
    *) config_fail "DATA_DIR must be an absolute path other than /" ;;
  esac

  if [ "$SYNC_MODE" = mirror ]; then
    config_fail "SYNC_MODE=mirror is not implemented in this version; use SYNC_MODE=archive (nothing is ever deleted in Nextcloud)"
  fi
  if [ "$EXTRACT_METADATA" = true ]; then
    config_fail "EXTRACT_METADATA=true is not implemented in this version"
  fi

  if [ "$CONFIG_ERRORS" -ne 0 ]; then
    log error config_rejected "errors=$CONFIG_ERRORS"
    return 1
  fi
}
