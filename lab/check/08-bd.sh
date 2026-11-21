#!/bin/bash
# Rung 8: a seat files a bd issue and you close it
# Run by lab/run, from the lab root, after it has checked this file's digest.
# Prints one RUNG line and exits 0 (PASS or SKIP) or 1 (FAIL). Read-only except
# where the rung says so. Dials nothing past this machine. No here-document and
# no here-string: bash 3.2 writes those to /tmp, which a locked-down run denies.

set -uo pipefail

ID=08
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

LABEL=lab-ticker-note
command -v bd >/dev/null 2>&1 || fail C-r8 "bd is not on PATH"
command -v python3 >/dev/null 2>&1 || fail C-r8 "python3 is not on PATH"

# parse_issue <label>: read bd JSON on stdin (a list or one object, or a one item list); print the
# id and status of the first issue that carries the label
parse_issue() {
  python3 -I -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
if isinstance(d, dict):
    d = [d]
for i in d:
    if sys.argv[1] in (i.get("labels") or []):
        print(i.get("id", ""), i.get("status", ""))
        break' "$1" 2>/dev/null
}

bounded "$WAIT" bd list --all --label "$LABEL" --json
[[ $B_RC -eq 0 ]] || fail C-r8 "bd list failed (exit $B_RC): are you in the lab orc?"
row=$(printf '%s' "$B_OUT" | parse_issue "$LABEL") || row=""
[[ -n $row ]] || fail C-r8 "no issue carries the $LABEL label: the bd-ticker seat has not filed one yet"
set -- $row
id=$1
status=$2
[[ $status == closed ]] || fail C-r8 "issue $id is $status: ask the agent to show it and close it"
bounded "$WAIT" bd show "$id" --json
[[ $B_RC -eq 0 ]] || fail C-r8 "bd show $id failed (exit $B_RC)"
shown=$(printf '%s' "$B_OUT" | python3 -I -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
if isinstance(d, list):
    d = d[0] if d else {}
print(d.get("status", ""))' 2>/dev/null) || shown=""
[[ $shown == closed ]] || fail C-r8 "bd show $id reads '${shown:-no status}', not closed"
pass
