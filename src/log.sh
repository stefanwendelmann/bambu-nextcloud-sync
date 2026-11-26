# shellcheck shell=sh
# Logging helpers. Log lines go to stderr so that functions can return data on stdout.

LOG_LEVEL_NUM=${LOG_LEVEL_NUM:-2}

log_level_to_num() {
  case "$1" in
    error) echo 0 ;;
    warn) echo 1 ;;
    info) echo 2 ;;
    debug) echo 3 ;;
    *) return 1 ;;
  esac
}

# Replaces the configured secrets and removes control characters, so that neither
# credentials nor forged log lines (for example from hostile file names) reach the output.
sanitize() {
  awk '
    function redact(s, secret,   out, i) {
      if (secret == "") return s
      out = ""
      while ((i = index(s, secret)) > 0) {
        out = out substr(s, 1, i - 1) "***"
        s = substr(s, i + length(secret))
      }
      return out s
    }
    {
      line = redact($0, ENVIRON["BAMBU_ACCESS_CODE"])
      line = redact(line, ENVIRON["NEXTCLOUD_APP_PASSWORD"])
      printf "%s ", line
    }' | tr -d '\000-\037\177' | sed 's/ $//'
}

# log LEVEL EVENT [key=value ...]
log() {
  local level="$1" event="$2" num line kv value
  shift 2
  num=$(log_level_to_num "$level") || num=2
  [ "$num" -le "$LOG_LEVEL_NUM" ] || return 0
  line="$(date '+%Y-%m-%dT%H:%M:%S%z') $(printf '%s' "$level" | tr '[:lower:]' '[:upper:]') $event"
  for kv in "$@"; do
    value=$(printf '%s' "${kv#*=}" | sanitize | sed 's/\\/\\\\/g; s/"/\\"/g')
    line="$line ${kv%%=*}=\"$value\""
  done
  printf '%s\n' "$line" >&2
}
