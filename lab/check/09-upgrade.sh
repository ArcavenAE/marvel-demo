#!/bin/bash
# Rung 9: roll back a manifest, then re-exec the daemon in place
# Run by lab/run, from the lab root, after it has checked this file's digest.
# Prints one RUNG line and exits 0 (PASS or SKIP) or 1 (FAIL). Read-only except
# where the rung says so. Dials nothing past this machine. No here-document and
# no here-string: bash 3.2 writes those to /tmp, which a locked-down run denies.

set -uo pipefail

ID=09
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

BASE=lab/state/09-baseline
command -v marvel >/dev/null 2>&1 || fail C-r9 "marvel is not on PATH"
command -v python3 >/dev/null 2>&1 || fail C-r9 "python3 is not on PATH"

# 1. Rollback: some ticker file shows v2 lines, and its newest line is v1 again.
rolled=0
for f in "$STATE"/ticker/*.log; do
  [[ -s $f ]] || continue
  if awk '/ v=v2$/ { s = 1; next } / v=v1$/ { if (s) back = 1; last = 1; next } { last = 0 } END { exit !(s && back && last) }' "$f"; then rolled=1; fi
done
[[ $rolled -eq 1 ]] || fail C-r9 "no ticker file shows v2 lines followed by v1 lines: apply v2, restart the seat, then apply v1 and restart it"

# 2. What the daemon and the seats look like now.
bounded "$WAIT" marvel version
[[ $B_RC -eq 0 ]] || fail C-r9 "marvel version failed (exit $B_RC)"
dline=$(printf '%s\n' "$B_OUT" | awk '$1 == "daemon" { print; exit }')
[[ -n $dline ]] || fail C-r9 "marvel version printed no daemon line"
commit=$(printf '%s' "$dline" | sed -n 's/.* commit \([^ ][^ ]*\).*/\1/p')
dpid=$(printf '%s' "$dline" | sed -n 's/.* pid \([0-9][0-9]*\).*/\1/p')
[[ -n $commit && -n $dpid ]] || fail C-r9 "could not read the daemon commit and pid from: $dline"
bounded "$WAIT" marvel get sessions -o json
[[ $B_RC -eq 0 ]] || fail C-r9 "marvel get sessions failed (exit $B_RC)"
seats=$(printf '%s\n' "$B_OUT" | sed -n '/^\[/,$p' | python3 -I -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
for s in sorted(d, key=lambda s: s.get("Name", "")):
    print("seat", s.get("Name", ""), s.get("PID", 0), s.get("PaneID", ""))' 2>/dev/null) || fail C-r9 "could not read marvel get sessions"
now=$(printf 'daemon %s %s\n%s\n' "$commit" "$dpid" "$seats")

# 3. No baseline yet: record one and ask for the upgrade.
if [[ ! -s $BASE ]]; then
  printf '%s\n' "$now" > "$BASE" 2>/dev/null || fail C-r9 "could not write the baseline $BASE"
  skip "baseline recorded in $BASE (daemon $commit); run marvel upgrade --daemon (or marvel daemon reexec) once a newer marvel is installed, then run this again"
fi
oldcommit=$(awk '$1 == "daemon" { print $2; exit }' "$BASE")
oldpid=$(awk '$1 == "daemon" { print $3; exit }' "$BASE")
if [[ $oldcommit == "$commit" ]]; then
  skip "the daemon build is unchanged since the baseline (commit $commit): install a newer marvel and run marvel upgrade --daemon, then run this again"
fi
[[ $oldpid == "$dpid" ]] || fail C-r9 "the daemon pid changed from $oldpid to $dpid: that is a restart, not a re-exec in place"
oldseats=$(awk '$1 == "seat"' "$BASE")
[[ $oldseats == "$seats" ]] || fail C-r9 "the seats changed across the re-exec: a session name, a process or a pane differs from the baseline"
pass
