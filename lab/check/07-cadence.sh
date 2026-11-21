#!/bin/bash
# Rung 7: a scheduled role opens a slot every two minutes
# Run by lab/run, from the lab root, after it has checked this file's digest.
# Prints one RUNG line and exits 0 (PASS or SKIP) or 1 (FAIL). Read-only except
# where the rung says so. Dials nothing past this machine. No here-document and
# no here-string: bash 3.2 writes those to /tmp, which a locked-down run denies.

set -uo pipefail

ID=07
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

WAIT_CAD=${LAB_WAIT_CADENCE:-270}
command -v marvel >/dev/null 2>&1 || fail C-r7 "marvel is not on PATH"

# The pass reads marvel's own cadence.slot-opened events, not the loop's file lines:
# two file lines two minutes apart would prove the loop's sleep, not marvel's schedule.
t0=$SECONDS
seen=""
while :; do
  bounded "$WAIT" marvel events --kind cadence.slot-opened
  if [[ $B_RC -ne 0 ]]; then
    seen="marvel events failed (exit $B_RC)"
  else
    res=$(printf '%s' "$B_OUT" | awk '
      $3 == "cadence.slot-opened" && $4 == "lab/cron-note" {
        split($1, t, ":"); s = t[1] * 3600 + t[2] * 60 + t[3]
        if (n > 0) prev = last
        last = s; n++
        if (n >= 2) delta = (last - prev + 86400) % 86400
      }
      END { if (n < 2) print "count " n + 0; else print "delta " delta }')
    case $res in
      "count "*) seen="${res#count } cadence.slot-opened event(s) for lab/cron-note, want two two minutes apart" ;;
      "delta "*)
        d=${res#delta }
        if [[ $d -ge 100 && $d -le 140 ]]; then pass; fi
        seen="the last two slots opened ${d}s apart, want about 120" ;;
      *) seen="no readable cadence.slot-opened events" ;;
    esac
  fi
  [[ $((SECONDS - t0)) -lt $WAIT_CAD ]] || break
  sleep 5
done
fail C-r7 "$seen"
