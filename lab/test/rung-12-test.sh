#!/usr/bin/env bash
# Tests for rung 12 (teardown): lab/check/12-teardown.sh and lab/rung/12-teardown.md.
# The check talks to marvel. Here marvel is a stub on a scratch PATH whose answers
# come from files in a state directory, and the stub records every call, so no test
# touches a real daemon, the real marvel home or the network. Run from anywhere:
#
#   env -i HOME="$(mktemp -d)" TMPDIR="$(mktemp -d)" PATH="$PATH" \
#     bash lab/test/rung-12-test.sh
#
# Prints `ok` or `not ok` per assertion and exits 1 if any failed.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lab-rung12.XXXXXX")
fails=0
n=0

ok() { n=$((n + 1)); printf 'ok %s %s\n' "$n" "$1"; }
bad() { n=$((n + 1)); fails=$((fails + 1)); printf 'not ok %s %s\n' "$n" "$1"; }
expect() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }

# fixture <name>: a fresh lab root with the real harness and the real check 12,
# a stub marvel on bin/, and a lab.lock that pins the check.
fixture() {
  FX=$WORK/$1
  ST=$FX/state-stub
  HM=$FX/home
  mkdir -p "$FX/lab/check" "$FX/lab/state" "$FX/bin" "$ST" "$HM"
  cp "$ROOT/lab/run" "$FX/lab/run"
  chmod +x "$FX/lab/run"
  for f in "$ROOT"/lab/check/12-*.sh; do
    [[ -e $f ]] && cp "$f" "$FX/lab/check/"
  done
  cp "$ROOT"/lab/test/stubs12/* "$FX/bin/"
  chmod +x "$FX"/bin/*
  put sessions.out "[]"
  put sessions.rc 0
  put config.out "     NAME   ADDRESS      IDENTITY
*    local  /scratch/marvel.sock  (default)  -"
  put config.rc 0
  : >"$ST/calls"
  LAB_ROOT=$FX "$FX/lab/run" digests >"$FX/lab.lock"
}
put() { printf '%s\n' "$2" >"$ST/$1"; }

lab() {
  OUT=$(env -i HOME="$HM" TMPDIR="$WORK" PATH="${LABPATH:-$FX/bin:/usr/bin:/bin}" \
    LAB_ROOT="$FX" LABT_STATE="$ST" LAB_WAIT="${LAB_WAIT:-3}" \
    "$FX/lab/run" check 12 2>&1) && RC=0 || RC=$?
}
verdict() {
  case $OUT in
    *"$2"*) [[ $RC -eq $3 ]] && ok "$1" || bad "$1: exit $RC, want $3: [$OUT]" ;;
    *) bad "$1: [$OUT] lacks [$2]" ;;
  esac
}
seat() {
  printf '{"Name":"%s","Workspace":"%s","Team":"ticker","Role":"ticker","State":"running","PID":4101,"PaneID":"%%1","Generation":1}' "$1" "$2"
}

# --- the check ------------------------------------------------------------------
fixture r12
lab
verdict "12 passes with no sessions and only the local cluster" "RUNG 12 PASS" 0
expect "12 ran only reads on marvel" "$(sort -u "$ST/calls" | tr '\n' ';')" "config list;get sessions -o json;"

put sessions.out "[$(seat other-ticker-g1-0 other)]"
lab
verdict "12 passes when a session belongs to another workspace" "RUNG 12 PASS" 0

put sessions.out "[$(seat ticker-ticker-g1-0 lab)]"
lab
verdict "12 FAILs while a seat is still running in the lab workspace" "RUNG 12 FAIL C-r12-a:" 1
case $OUT in *"ticker-ticker-g1-0"*) ok "12 names the seat that is left" ;; *) bad "12 does not name the seat that is left: [$OUT]" ;; esac

put sessions.out "[$(seat other-ticker-g1-0 other),$(seat ticker-ticker-g1-0 lab)]"
lab
verdict "12 FAILs when a lab seat sits beside another workspace's seat" "RUNG 12 FAIL C-r12-a:" 1

put sessions.out "Error: connect to daemon at /scratch/marvel.sock (unix): dial unix /scratch/marvel.sock: connect: no such file or directory"
put sessions.rc 1
lab
verdict "12 passes when the daemon is stopped (marvel stop --teardown ran)" "RUNG 12 PASS" 0

put sessions.out "boom: something else broke"
put sessions.rc 1
lab
verdict "12 FAILs when marvel get sessions fails for another reason" "RUNG 12 FAIL C-r12-a:" 1

put sessions.out "not json at all"
put sessions.rc 0
lab
verdict "12 FAILs when the sessions answer cannot be read" "RUNG 12 FAIL C-r12-a:" 1

put sessions.out "[]"
put sessions.rc 0
put config.out "     NAME     ADDRESS               IDENTITY
*    local    /scratch/marvel.sock  (default)  -
     friend   mrvl://friend-mac     -"
lab
verdict "12 FAILs while a cluster beyond local is still configured" "RUNG 12 FAIL C-r12-b:" 1
case $OUT in *"friend"*) ok "12 names the cluster that is left" ;; *) bad "12 does not name the cluster that is left: [$OUT]" ;; esac

put config.out "     NAME   ADDRESS              IDENTITY
     local  /scratch/marvel.sock  (default)  -"
lab
verdict "12 passes when local is not the current cluster but is the only one" "RUNG 12 PASS" 0

put config.out "boom"
put config.rc 1
lab
verdict "12 FAILs when marvel config list fails" "RUNG 12 FAIL C-r12-b:" 1

put config.out ""
put config.rc 0
lab
verdict "12 FAILs when marvel config list prints nothing" "RUNG 12 FAIL C-r12-b:" 1

LABPATH=/usr/bin:/bin lab
verdict "12 FAILs when marvel is not on PATH" "RUNG 12 FAIL C-r12:" 1

# The check never acts: a script that mentions a mutating verb fails the static test.
script=$ROOT/lab/check/12-teardown.sh
if [[ -f $script ]]; then
  for verb in "marvel stop" "marvel keys" "remove-cluster" "marvel kill" "marvel delete" "bd close" "gh " "rm " "git "; do
    if grep -v '^[[:space:]]*#' "$script" | grep -q -F -e "$verb"; then bad "check 12 runs no [$verb]"; else ok "check 12 runs no [$verb]"; fi
  done
else
  bad "check 12 exists to be scanned for mutating verbs"
fi

# --- the lock and the instructions ----------------------------------------------
want=$(LAB_ROOT=$ROOT "$ROOT/lab/run" digests | awk '$2 ~ "lab/check/12-" {print $0}')
if [[ -z $want ]]; then bad "rung 12 has a check script"; elif grep -q -F -x "$want" "$ROOT/lab.lock"; then ok "rung 12 check is pinned in the real lab.lock"; else bad "rung 12 check is not pinned in the real lab.lock"; fi
md=$(ls "$ROOT"/lab/rung/12-*.md 2>/dev/null | head -1 || true)
if [[ -z $md ]]; then
  bad "rung 12 has instructions"
else
  section() { awk -v h="## $1" '$0 == h {on=1; next} /^## /{on=0} on' "$md"; }
  body=$(cat "$md")
  if [[ -s $md ]] && ! grep -q '^RUNG ' "$md"; then ok "rung 12 instructions exist and hold no verdict line"; else bad "rung 12 instructions are empty or hold a verdict line"; fi
  if command -v just >/dev/null 2>&1; then
    printed=$(cd "$ROOT" && just lab rung 12 2>&1) || printed="just failed"
    if [[ $printed == "$body" ]]; then ok "rung 12 instructions are printed by just lab rung"; else bad "rung 12 instructions differ from just lab rung output"; fi
  else
    bad "just is not on PATH, so rung 12's printout was not tested"
  fi
  [[ -n $(section Tools) ]] && ok "rung 12 has a Tools section" || bad "rung 12 has no Tools section"
  [[ -n $(section "Expected prompts") ]] && ok "rung 12 has an Expected prompts section" || bad "rung 12 has no Expected prompts section"
  [[ -n $(section "Left in place") ]] && ok "rung 12 has a Left in place section" || bad "rung 12 has no Left in place section"
  for s in "lab report 12" "collaborator" "marvel stop --teardown" "marvel keys revoke" "marvel config remove-cluster" "just lab check 12"; do
    case $body in *"$s"*) ok "rung 12 names $s" ;; *) bad "rung 12 does not name $s" ;; esac
  done
  # the report comes before the collaborator is removed
  head=${body%%collaborator*}
  case $head in *"lab report 12"*) ok "rung 12 puts lab report 12 before the collaborator" ;; *) bad "rung 12 does not put lab report 12 before the collaborator" ;; esac
  left=$(section "Left in place")
  for s in "~/.marvel" "~/lab-run" "bd" "brew" "Remote Login" "Local Network" "pmset -c sleep 0"; do
    case $left in *"$s"*) ok "rung 12 Left in place names $s" ;; *) bad "rung 12 Left in place does not name $s" ;; esac
  done
fi

# --- hygiene --------------------------------------------------------------------
userpath="/Use""rs/"
emdash=$'\xe2\x80\x94'
for f in "$ROOT"/lab/check/12-*.sh "$ROOT"/lab/rung/12-*.md "$ROOT"/lab/test/rung-12-test.sh "$ROOT"/lab/test/stubs12/marvel; do
  [[ -f $f ]] || { bad "${f#"$ROOT"/} exists"; continue; }
  if grep -q -e "$userpath" -e "$emdash" "$f"; then bad "${f#"$ROOT"/} has a user path or an em dash"; else ok "${f#"$ROOT"/} has no user path or em dash"; fi
done

printf '\n%s assertions, %s failed\n' "$n" "$fails"
[[ $fails -eq 0 ]] || exit 1
