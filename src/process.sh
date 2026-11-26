# shellcheck shell=sh
# Child process helpers that keep the service responsive to SIGTERM/SIGINT.

STOP=0
CHILD_PID=

on_stop_signal() {
  STOP=1
  [ -z "$CHILD_PID" ] || kill "$CHILD_PID" 2>/dev/null
}

# Runs a command in the background and waits for it, so that a stop signal can end it
# immediately instead of after a long transfer.
run_child() {
  local rc
  "$@" &
  CHILD_PID=$!
  while :; do
    wait "$CHILD_PID"
    rc=$?
    # A trapped signal interrupts wait while the child may still be running.
    kill -0 "$CHILD_PID" 2>/dev/null || break
  done
  CHILD_PID=
  return "$rc"
}

interruptible_sleep() {
  sleep "$1" &
  CHILD_PID=$!
  wait "$CHILD_PID" 2>/dev/null
  kill "$CHILD_PID" 2>/dev/null
  CHILD_PID=
}
