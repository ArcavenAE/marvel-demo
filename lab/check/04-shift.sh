#!/bin/bash
# Rung 4: a shift with a handoff
# Run by lab/run, from the lab root, after it has checked this file's digest.
# Prints one RUNG line and exits 0 (PASS or SKIP) or 1 (FAIL). Read-only except
# where the rung says so. Dials nothing past this machine. No here-document and
# no here-string: bash 3.2 writes those to /tmp, which a locked-down run denies.

set -uo pipefail

ID=04
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

command -v marvel >/dev/null 2>&1 || fail C-r4 "marvel is not on PATH"

t0=$SECONDS
seen=""
while :; do
  # the highest generation file is the successor; the files of a lower generation are predecessors
  succ=""
  succgen=0
  for f in "$STATE"/ticker/*.log; do
    [[ -s $f ]] || continue
    g=$(head -n 1 "$f" | sed -n 's/.* gen=\([0-9][0-9]*\) .*/\1/p')
    [[ -n $g ]] || continue
    if [[ $g -gt $succgen ]]; then succgen=$g; succ=$f; fi
  done
  if [[ $succgen -lt 2 ]]; then
    seen="no ticker file from a second generation: run marvel shift lab/ticker --role ticker"
  else
    k=$(head -n 1 "$succ" | sed -n 's/.* count=\([0-9][0-9]*\) .*/\1/p')
    if [[ -z $k || $k -le 1 ]]; then
      fail C-r4 "the successor ${succ##*/} starts at count ${k:-?}: it did not continue a predecessor's count"
    fi
    found=0
    for f in "$STATE"/ticker/*.log; do
      [[ $f == "$succ" ]] && continue
      if grep -q -E " gen=[0-9]+ count=$((k - 1)) " "$f"; then found=1; fi
    done
    if [[ $found -eq 0 ]]; then
      fail C-r4 "the successor ${succ##*/} starts at count $k, but no predecessor file reached count $((k - 1))"
    fi
    bounded "$WAIT" marvel events --kind team.shift-completed
    if printf '%s' "$B_OUT" | awk '$3 == "team.shift-completed" && $4 == "lab/ticker" { f = 1 } END { exit !f }'; then
      pass
    fi
    seen="marvel records no team.shift-completed event for lab/ticker"
  fi
  [[ $((SECONDS - t0)) -lt $WAIT ]] || break
  sleep 1
done
fail C-r4 "$seen"
