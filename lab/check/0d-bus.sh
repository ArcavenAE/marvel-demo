#!/bin/bash
# Rung 0d: the managed bus is local only
# Run by lab/run, from the lab root, after it has checked this file's digest.
# Prints one RUNG line and exits 0 (PASS or SKIP) or 1 (FAIL). Read-only except
# where the rung says so. Dials nothing past this machine. No here-document and
# no here-string: bash 3.2 writes those to /tmp, which a locked-down run denies.

set -uo pipefail

ID=0d
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

command -v marvel >/dev/null 2>&1 || fail C-r0-d "marvel is not on PATH"
command -v nc >/dev/null 2>&1 || fail C-r0-d "nc is not on PATH"
bounded "$WAIT" marvel bus status
[[ $B_RC -eq 0 ]] || fail C-r0-d "marvel bus status failed (exit $B_RC)"
printf '%s' "$B_OUT" | grep -q -E '^ready: +yes$' || fail C-r0-d "the bus is not ready: $(printf '%s' "$B_OUT" | grep -m1 '^ready:' || true)"
leaf=$(printf '%s' "$B_OUT" | sed -n 's/^leaf: *//p' | head -n 1)
case $leaf in
  up*) fail C-r0-d "a hub leaf link is up: leaf $leaf" ;;
esac
listen=$(printf '%s' "$B_OUT" | sed -n 's/^listen: *//p' | head -n 1)
case $listen in
  127.0.0.1:*|localhost:*) ;;
  *) fail C-r0-d "the bus listens on $listen, not on localhost" ;;
esac
port=${listen##*:}

bounded "$WAIT" nc -z 127.0.0.1 "$port"
[[ $B_RC -eq 0 ]] || fail C-r0-d "127.0.0.1:$port refused a connection"

lan=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
[[ -n $lan ]] || skip "no LAN address on this host, so the LAN refusal was not tested"
bounded "$WAIT" nc -z "$lan" "$port"
[[ $B_RC -ne 0 ]] || fail C-r0-d "the bus accepts connections on the LAN address $lan:$port"
pass
