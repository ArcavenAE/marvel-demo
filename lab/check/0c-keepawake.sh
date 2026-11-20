#!/bin/bash
# Rung 0c: marvel accepts the keepawake file, and a killed keepawake session is held again
# Run by lab/run, from the lab root, after it has checked this file's digest.
# Prints one RUNG line and exits 0 (PASS or SKIP) or 1 (FAIL). Read-only except
# where the rung says so. Dials nothing past this machine. No here-document and
# no here-string: bash 3.2 writes those to /tmp, which a locked-down run denies.

set -uo pipefail

ID=0c
WAIT=${LAB_WAIT:-10}

pass() { printf 'RUNG %s PASS\n' "$ID"; exit 0; }
skip() { printf 'RUNG %s SKIP %s\n' "$ID" "$*"; exit 0; }
# fail <check-id> <what was seen>: the seen text is cut to one short line
fail() {
  local cid=$1 seen
  shift
  seen=$(printf '%s' "$*" | tr '\n' ' ' | cut -c1-200)
  printf 'RUNG %s FAIL %s: %s\n' "$ID" "$cid" "$seen"
  exit 1
}

# bounded <secs> <command words...>: run a command with no stdin, stop it by
# its pid when it does not finish in time. Sets B_OUT (its output) and B_RC
# (its exit status, 127 if it is not found, 124 if it timed out).
bounded() {
  local secs=$1 pids="" wpid cpid line t0 left
  shift
  B_OUT=""
  B_RC=0
  exec 7< <(sh -c '"$@" 2>&1 </dev/null & c=$!; echo "$$ $c"; wait $c; echo "__RC=$?"' sh "$@")
  t0=$SECONDS
  read -r -t "$secs" pids <&7 || true
  wpid=${pids%% *}
  cpid=${pids##* }
  while :; do
    left=$((secs - (SECONDS - t0)))
    if [[ $left -le 0 ]]; then B_RC=124; break; fi
    if read -r -t "$left" line <&7; then
      case $line in
        __RC=*) B_RC=${line#__RC=}; break ;;
      esac
      B_OUT="$B_OUT$line"$'\n'
    else
      B_RC=124
      break
    fi
  done
  if [[ $B_RC -eq 124 ]]; then
    for p in $cpid $wpid; do
      case $p in ''|*[!0-9]*) continue ;; esac
      kill -TERM "$p" 2>/dev/null || true
    done
    sleep 0.2
    for p in $cpid $wpid; do
      case $p in ''|*[!0-9]*) continue ;; esac
      if kill -0 "$p" 2>/dev/null; then kill -KILL "$p" 2>/dev/null || true; fi
    done
  fi
  exec 7<&-
}

# lock_value <kind> <name>: the third field of the lab.lock line `<kind> <name> <value>`
lock_value() { awk -v k="$1" -v n="$2" '$1 == k && $2 == n { print $3; exit }' lab.lock; }

POLL=${LAB_WAIT:-30}
command -v marvel >/dev/null 2>&1 || fail C-r0-c "marvel is not on PATH"
command -v pmset >/dev/null 2>&1 || fail C-r0-c "pmset is not on PATH"

# The keepawake file is one marvel accepts.
bounded "$WAIT" marvel plan -f manifests/keepawake.toml
[[ $B_RC -eq 0 ]] || fail C-r0-c "marvel plan rejects manifests/keepawake.toml (exit $B_RC): $B_OUT"

# session_row: sets S_STATE, S_PID, S_WS, S_NAME from the keepawake session.
session_row() {
  bounded "$WAIT" marvel get sessions -o json
  [[ $B_RC -eq 0 ]] || return 1
  local row
  row=$(printf '%s' "$B_OUT" | python3 -I -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
for s in d:
    if s.get("Team") == "keepawake" and s.get("Role") == "caffeinate":
        print(s.get("State", ""), s.get("PID", 0), s.get("Workspace", ""), s.get("Name", ""))
        break' 2>/dev/null) || return 1
  [[ -n $row ]] || return 1
  set -- $row
  S_STATE=$1 S_PID=$2 S_WS=$3 S_NAME=$4
  return 0
}
# holds <pid>: pmset shows PreventUserIdleSystemSleep owned by that pid
holds() {
  bounded "$WAIT" pmset -g assertions
  printf '%s' "$B_OUT" | grep -q "pid $1(.*PreventUserIdleSystemSleep"
}

session_row || fail C-r0-c "no keepawake session in marvel get sessions"
[[ $S_STATE == running && $S_PID -gt 0 ]] || fail C-r0-c "the keepawake session is $S_STATE (pid $S_PID), not running"
OLD=$S_PID
KEY="$S_WS/$S_NAME"
holds "$OLD" || fail C-r0-c "pmset shows no PreventUserIdleSystemSleep from the session pid $OLD"

bounded "$WAIT" marvel kill "$KEY"
t0=$SECONDS
seen="no change"
while [[ $((SECONDS - t0)) -lt $POLL ]]; do
  if session_row && [[ $S_STATE == running && $S_PID -gt 0 && $S_PID -ne $OLD ]]; then
    if holds "$S_PID"; then pass; fi
    seen="new pid $S_PID, but pmset shows no assertion from it"
  elif session_row; then
    seen="session $S_STATE, pid $S_PID"
  fi
  sleep 0.5
done
fail C-r0-c "no new pid held the assertion within ${POLL}s of the kill (old pid $OLD; $seen)"
