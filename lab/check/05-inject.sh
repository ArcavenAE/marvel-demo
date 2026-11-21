#!/bin/bash
# Rung 5: inject and capture a nonce
# Run by lab/run, from the lab root, after it has checked this file's digest.
# Prints one RUNG line and exits 0 (PASS or SKIP) or 1 (FAIL). Read-only except
# where the rung says so. Dials nothing past this machine. No here-document and
# no here-string: bash 3.2 writes those to /tmp, which a locked-down run denies.

set -uo pipefail

ID=05
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

NONCE_FILE=lab/state/nonce-05
command -v marvel >/dev/null 2>&1 || fail C-r5 "marvel is not on PATH"
command -v python3 >/dev/null 2>&1 || fail C-r5 "python3 is not on PATH"

bounded "$WAIT" marvel get sessions -o json
[[ $B_RC -eq 0 ]] || fail C-r5 "marvel get sessions failed (exit $B_RC)"
line=$(printf '%s' "$B_OUT" | sess ticker ticker | awk '$1 == "running" { print; exit }')
[[ -n $line ]] || fail C-r5 "no running ticker session to capture"
set -- $line
key=$3/$4

# This check never runs marvel inject: typing into a pane is the human's step.
if [[ ! -s $NONCE_FILE ]]; then
  skip "no nonce: write a random word to $NONCE_FILE, run marvel inject $key with it yourself, then run this again"
fi
nonce=$(head -n 1 "$NONCE_FILE")
bounded "$WAIT" marvel capture "$key"
[[ $B_RC -eq 0 ]] || fail C-r5 "marvel capture $key failed (exit $B_RC)"
printf '%s' "$B_OUT" | grep -qF -- "$nonce" || fail C-r5 "marvel capture of $key does not show the nonce you injected"
pass
