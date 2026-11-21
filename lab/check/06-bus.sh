#!/bin/bash
# Rung 6: two seats talk over the managed bus
# Run by lab/run, from the lab root, after it has checked this file's digest.
# Prints one RUNG line and exits 0 (PASS or SKIP) or 1 (FAIL). Read-only except
# where the rung says so. Dials nothing past this machine. No here-document and
# no here-string: bash 3.2 writes those to /tmp, which a locked-down run denies.

set -uo pipefail

ID=06
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


STATE=${LAB_STATE:-$HOME/lab-run}

# sess <team> <role>: read marvel get sessions -o json on stdin, print one line per
# matching session: state pid workspace name pane generation
sess() {
  python3 -I -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
for s in d:
    if s.get("Team") == sys.argv[1] and s.get("Role") == sys.argv[2]:
        print(s.get("State", ""), s.get("PID", 0), s.get("Workspace", ""), s.get("Name", ""), s.get("PaneID", ""), s.get("Generation", 0))' "$1" "$2" 2>/dev/null
}

FRESH=${LAB_FRESH:-30}
command -v marvel >/dev/null 2>&1 || fail C-r6 "marvel is not on PATH"
command -v python3 >/dev/null 2>&1 || fail C-r6 "python3 is not on PATH"

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# evaluate: set SEEN to what is wrong and return 1, or return 0 on a live exchange.
evaluate() {
  bounded "$WAIT" marvel bus status
  [[ $B_RC -eq 0 ]] || { SEEN="marvel bus status failed (exit $B_RC)"; return 1; }
  printf '%s' "$B_OUT" | grep -q -E '^ready: +yes$' || { SEEN="the bus is not ready: $(printf '%s' "$B_OUT" | grep -m1 '^ready:' || true)"; return 1; }
  local leaf
  leaf=$(printf '%s' "$B_OUT" | sed -n 's/^leaf: *//p' | head -n 1)
  [[ $leaf == "n/a" || $leaf == "n/a "* ]] || { SEEN="the bus leaf reads '$leaf', not n/a: a hub is configured"; return 1; }
  bounded "$WAIT" marvel get sessions -o json
  [[ $B_RC -eq 0 ]] || { SEEN="marvel get sessions failed (exit $B_RC)"; return 1; }
  local json=$B_OUT pong ping
  pong=$(printf '%s' "$json" | sess relay pong | awk '$1 == "running" { print $4; exit }')
  ping=$(printf '%s' "$json" | sess relay ping | awk '$1 == "running" { print $4; exit }')
  [[ -n $pong ]] || { SEEN="no running pong seat in the relay team"; return 1; }
  [[ -n $ping ]] || { SEEN="no running ping seat in the relay team"; return 1; }
  local pf=$STATE/relay/$pong.log gf=$STATE/relay/$ping.log
  [[ -s $pf ]] || { SEEN="the pong seat's log $pong.log is empty or missing"; return 1; }
  local n now m
  n=$(grep -E ' heard ping [0-9]+$' "$pf" | tail -n 1 | awk '{ print $NF }')
  [[ -n $n ]] || { SEEN="the pong seat's log has no 'heard ping <n>' line"; return 1; }
  now=$(date +%s)
  m=$(mtime "$pf")
  [[ -n $m && $((now - m)) -le $FRESH ]] || { SEEN="the pong seat's log has not changed in ${FRESH}s: the exchange is not live"; return 1; }
  grep -qx "pong $n" "$gf" 2>/dev/null || { SEEN="the ping seat's log never saw the answer 'pong $n' to the newest ping"; return 1; }
  return 0
}

t0=$SECONDS
SEEN=""
while :; do
  if evaluate; then pass; fi
  [[ $((SECONDS - t0)) -lt $WAIT ]] || break
  sleep 1
done
fail C-r6 "$SEEN"
