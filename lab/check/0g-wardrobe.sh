#!/bin/bash
# Rung 0g: wardrobe is read-only and named by WARDROBE_ROOT
# Run by lab/run, from the lab root, after it has checked this file's digest.
# Prints one RUNG line and exits 0 (PASS or SKIP) or 1 (FAIL). Read-only except
# where the rung says so. Dials nothing past this machine. No here-document and
# no here-string: bash 3.2 writes those to /tmp, which a locked-down run denies.

set -uo pipefail

ID=0g
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

tag=$(lock_value release wardrobe)
[[ -n $tag ]] || skip "no published release"
[[ -n ${WARDROBE_ROOT:-} && -d $WARDROBE_ROOT ]] || fail C-r0-g "WARDROBE_ROOT is not set to a directory"
dir=${LAB_WARDROBE_DIR:-wardrobe}
[[ -d $dir ]] || fail C-r0-g "no wardrobe checkout at $dir"
bounded "$WAIT" sh -c 'cd "$1" && exec just root' sh "$dir"
[[ $B_RC -eq 0 ]] || fail C-r0-g "just root failed (exit $B_RC)"
got=$(printf '%s' "$B_OUT" | head -n 1)
want='(WARDROBE_ROOT; no ./contents beside the justfile)'
[[ $got == "$want" ]] || fail C-r0-g "just root reads: $got"
if [[ -w $WARDROBE_ROOT ]]; then fail C-r0-g "WARDROBE_ROOT is writable"; fi
pass
