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
# stub marvel and lsof on bin/, a gh stub that only records a call (the check must
# make none), a git origin whose owner is the account that should remain, the
# collaborator and invitation listings the human saved under lab/state, a scratch ~/.marvel with an authorized_keys file, one lab key
# recorded in lab/state/lab-keys, and a lab.lock that pins the check. The real
# ssh-keygen reads the keys; it writes only under scratch.
fixture() {
  FX=$WORK/$1
  ST=$FX/state-stub
  HM=$FX/home
  mkdir -p "$FX/lab/check" "$FX/lab/state" "$FX/bin" "$ST" "$HM/.marvel"
  cp "$ROOT/lab/run" "$FX/lab/run"
  chmod +x "$FX/lab/run"
  for f in "$ROOT"/lab/check/12-*.sh; do
    [[ -e $f ]] && cp "$f" "$FX/lab/check/"
  done
  cp "$ROOT"/lab/test/stubs12/* "$FX/bin/"
  chmod +x "$FX"/bin/*
  git -C "$FX" init -q
  git -C "$FX" remote add origin https://github.com/newcomer/lab-kit
  # three keys: the lab key, an unrelated key, and a second lab key
  for k in lab other lab2; do
    ssh-keygen -q -t ed25519 -N "" -C "$k@scratch" -f "$FX/key-$k" >/dev/null
  done
  cat "$FX/key-other.pub" >"$HM/.marvel/authorized_keys"
  ssh-keygen -lf "$FX/key-lab.pub" | awk '{print $2}' >"$FX/lab/state/lab-keys"
  LABFP=$(awk '{print $1; exit}' "$FX/lab/state/lab-keys")
  LAB2FP=$(ssh-keygen -lf "$FX/key-lab2.pub" | awk '{print $2}')
  put sessions.out "[]"
  put sessions.rc 0
  put config.out "     NAME   ADDRESS      IDENTITY
*    local  /scratch/marvel.sock  (default)  -"
  put config.rc 0
  # the human's listings, saved after the teardown started: the marker is older
  touch -t 202611210100 "$FX/lab/state/teardown-start"
  printf 'newcomer\n' >"$FX/lab/state/collaborators"
  : >"$FX/lab/state/invitations"
  touch -t 202611210200 "$FX/lab/state/collaborators" "$FX/lab/state/invitations"
  : >"$ST/calls"
  LAB_ROOT=$FX "$FX/lab/run" digests >"$FX/lab.lock"
}
put() { printf '%s\n' "$2" >"$ST/$1"; }

lab() {
  OUT=$(env -i HOME="$HM" TMPDIR="$WORK" PATH="${LABPATH:-$FX/bin:/usr/bin:/bin}" \
    LAB_ROOT="$FX" LABT_STATE="$ST" LAB_WAIT="${LAB_WAIT:-3}" LAB_PORTS="${LAB_PORTS:-4222}" \
    "$FX/lab/run" check 12 2>&1) && RC=0 || RC=$?
}
verdict() {
  case $OUT in
    *"$2"*) [[ $RC -eq $3 ]] && ok "$1" || bad "$1: exit $RC, want $3: [$OUT]" ;;
    *) bad "$1: [$OUT] lacks [$2]" ;;
  esac
}
named() { case $OUT in *"$2"*) ok "$1" ;; *) bad "$1: [$OUT] lacks [$2]" ;; esac; }
seat() {
  printf '{"Name":"%s","Workspace":"%s","Team":"ticker","Role":"ticker","State":"running","PID":4101,"PaneID":"%%1","Generation":1}' "$1" "$2"
}

# --- the baseline: everything torn down ------------------------------------------
fixture r12
lab
verdict "12 passes when the lab is torn down" "RUNG 12 PASS" 0
calls=$(sort -u "$ST/calls" | tr '\n' ';')
for c in "marvel config list" "marvel get sessions -o json" "lsof -nP -iTCP:4222"; do
  case $calls in *"$c"*) ok "12 read through [$c]" ;; *) bad "12 did not read through [$c]: [$calls]" ;; esac
done
# every gh call is a plain read: no method flag, no field, no input
if grep -q '^gh ' "$ST/calls"; then bad "12 called gh: it makes no live call"; else ok "12 calls no gh"; fi
if grep -q -E '^marvel (stop|keys|kill|delete|apply|work)' "$ST/calls"; then bad "12 ran a marvel verb that acts"; else ok "12 ran no marvel verb that acts"; fi

# --- C-td-1: no listener on the lab ports ----------------------------------------
put lsof.4222 "4242"
lab
verdict "C-td-1 FAILs while a process listens on the bus port" "RUNG 12 FAIL C-td-1:" 1
named "C-td-1 names the port" "4222"
: >"$ST/lsof.4222"
put lsof.4333 "777"
LAB_PORTS="4222 4333" lab
verdict "C-td-1 FAILs on the second of two lab ports" "RUNG 12 FAIL C-td-1:" 1
named "C-td-1 names the second port" "4333"
LAB_PORTS="4222" lab
verdict "C-td-1 passes when only a port outside the lab list listens" "RUNG 12 PASS" 0
: >"$ST/lsof.4333"
mv "$FX/bin/lsof" "$FX/lsof.away"
lab
verdict "C-td-1 FAILs when lsof is not there to look" "RUNG 12 FAIL C-td-1:" 1
mv "$FX/lsof.away" "$FX/bin/lsof"

# --- C-td-2: the lab key is gone from authorized_keys ----------------------------
cat "$FX/key-lab.pub" >>"$HM/.marvel/authorized_keys"
lab
verdict "C-td-2 FAILs while the lab key is still authorized" "RUNG 12 FAIL C-td-2:" 1
named "C-td-2 names the fingerprint" "$LABFP"
cat "$FX/key-other.pub" >"$HM/.marvel/authorized_keys"
lab
verdict "C-td-2 passes once only an unrelated key remains" "RUNG 12 PASS" 0
printf '%s\n' "$LABFP" "$LAB2FP" >"$FX/lab/state/lab-keys"
cat "$FX/key-lab2.pub" >>"$HM/.marvel/authorized_keys"
lab
verdict "C-td-2 FAILs on the second of two lab keys" "RUNG 12 FAIL C-td-2:" 1
named "C-td-2 names the second fingerprint" "$LAB2FP"
cat "$FX/key-other.pub" >"$HM/.marvel/authorized_keys"
mv "$HM/.marvel/authorized_keys" "$HM/.marvel/authorized_keys.away"
lab
verdict "C-td-2 passes when the host has no authorized_keys file at all" "RUNG 12 PASS" 0
mv "$HM/.marvel/authorized_keys.away" "$HM/.marvel/authorized_keys"
mv "$FX/lab/state/lab-keys" "$FX/lab-keys.away"
lab
verdict "C-td-2 FAILs when the lab key list was never recorded" "RUNG 12 FAIL C-td-2:" 1
printf 'not-a-fingerprint\n' >"$FX/lab/state/lab-keys"
lab
verdict "C-td-2 FAILs on a lab key list that holds no fingerprint" "RUNG 12 FAIL C-td-2:" 1
: >"$FX/lab/state/lab-keys"
lab
verdict "C-td-2 FAILs on an empty lab key list" "RUNG 12 FAIL C-td-2:" 1
mv "$FX/lab-keys.away" "$FX/lab/state/lab-keys"
printf 'garbage that is not a key\n' >"$HM/.marvel/authorized_keys"
lab
verdict "C-td-2 FAILs when authorized_keys cannot be read as keys" "RUNG 12 FAIL C-td-2:" 1
cat "$FX/key-other.pub" >"$HM/.marvel/authorized_keys"

# --- C-td-3: the collaborator is gone, read from the listings you saved ----------
# The check calls no gh. It reads lab/state/collaborators and lab/state/invitations,
# which the human saved with gh after the teardown started (lab/state/teardown-start).
printf 'newcomer\ninvitee-login\n' >"$FX/lab/state/collaborators"
touch -t 202611210200 "$FX/lab/state/collaborators"
lab
verdict "C-td-3 FAILs while a second collaborator is still listed" "RUNG 12 FAIL C-td-3:" 1
named "C-td-3 names the collaborator" "invitee-login"
printf 'newcomer\n' >"$FX/lab/state/collaborators"
touch -t 202611210200 "$FX/lab/state/collaborators"
printf 'invitee-login\n' >"$FX/lab/state/invitations"
touch -t 202611210200 "$FX/lab/state/invitations"
lab
verdict "C-td-3 FAILs while an invitation is still pending" "RUNG 12 FAIL C-td-3:" 1
named "C-td-3 names the invited login" "invitee-login"
: >"$FX/lab/state/invitations"
touch -t 202611210200 "$FX/lab/state/invitations"
printf 'NewComer\n' >"$FX/lab/state/collaborators"
touch -t 202611210200 "$FX/lab/state/collaborators"
lab
verdict "C-td-3 compares the owner's login without regard to case" "RUNG 12 PASS" 0
printf 'newcomer\n' >"$FX/lab/state/collaborators"
touch -t 202611210200 "$FX/lab/state/collaborators"
mv "$FX/lab/state/collaborators" "$FX/collab.away"
lab
verdict "C-td-3 FAILs when the collaborator listing was never saved" "RUNG 12 FAIL C-td-3:" 1
mv "$FX/collab.away" "$FX/lab/state/collaborators"
mv "$FX/lab/state/invitations" "$FX/invites.away"
lab
verdict "C-td-3 FAILs when the invitation listing was never saved" "RUNG 12 FAIL C-td-3:" 1
mv "$FX/invites.away" "$FX/lab/state/invitations"
touch -t 202611210030 "$FX/lab/state/collaborators"
lab
verdict "C-td-3 FAILs when the collaborator listing is older than the teardown start" "RUNG 12 FAIL C-td-3:" 1
named "C-td-3 says the listing is stale" "older"
touch -t 202611210200 "$FX/lab/state/collaborators"
touch -t 202611210030 "$FX/lab/state/invitations"
lab
verdict "C-td-3 FAILs when the invitation listing is older than the teardown start" "RUNG 12 FAIL C-td-3:" 1
touch -t 202611210200 "$FX/lab/state/invitations"
mv "$FX/lab/state/teardown-start" "$FX/start.away"
lab
verdict "C-td-3 FAILs when the teardown start was never marked" "RUNG 12 FAIL C-td-3:" 1
mv "$FX/start.away" "$FX/lab/state/teardown-start"
: >"$FX/lab/state/collaborators"
touch -t 202611210200 "$FX/lab/state/collaborators"
lab
verdict "C-td-3 FAILs on an empty collaborator listing" "RUNG 12 FAIL C-td-3:" 1
printf 'newcomer\n' >"$FX/lab/state/collaborators"
touch -t 202611210200 "$FX/lab/state/collaborators"
git -C "$FX" remote set-url origin git@example.invalid:newcomer/lab-kit.git
lab
verdict "C-td-3 FAILs when origin is not a github.com repository" "RUNG 12 FAIL C-td-3:" 1
git -C "$FX" remote set-url origin https://github.com/other-owner/lab-kit
lab
verdict "C-td-3 FAILs when the listing does not name the origin's owner" "RUNG 12 FAIL C-td-3:" 1
git -C "$FX" remote set-url origin https://github.com/newcomer/lab-kit
if grep -q '^gh ' "$ST/calls"; then bad "C-td-3 called gh: it makes no live call"; else ok "C-td-3 made no gh call across every case"; fi
lab
verdict "12 passes again once the listings are fresh and name only the owner" "RUNG 12 PASS" 0

# --- the extras: no lab seat, and no cluster beyond local ------------------------
put sessions.out "[$(seat other-ticker-g1-0 other)]"
lab
verdict "12 passes when a session belongs to another workspace" "RUNG 12 PASS" 0
put sessions.out "[$(seat ticker-ticker-g1-0 lab)]"
lab
verdict "C-td-4 FAILs while a seat is still running in the lab workspace" "RUNG 12 FAIL C-td-4:" 1
named "C-td-4 names the seat that is left" "ticker-ticker-g1-0"
put sessions.out "[$(seat other-ticker-g1-0 other),$(seat ticker-ticker-g1-0 lab)]"
lab
verdict "C-td-4 FAILs when a lab seat sits beside another workspace's seat" "RUNG 12 FAIL C-td-4:" 1
put sessions.out "Error: connect to daemon at /scratch/marvel.sock (unix): dial unix /scratch/marvel.sock: connect: no such file or directory"
put sessions.rc 1
lab
verdict "12 passes when the daemon is stopped (marvel stop --teardown ran)" "RUNG 12 PASS" 0
put sessions.out "boom: something else broke"
lab
verdict "C-td-4 FAILs when marvel get sessions fails for another reason" "RUNG 12 FAIL C-td-4:" 1
put sessions.out "not json at all"
put sessions.rc 0
lab
verdict "C-td-4 FAILs when the sessions answer cannot be read" "RUNG 12 FAIL C-td-4:" 1
put sessions.out "[]"
put config.out "     NAME     ADDRESS               IDENTITY
*    local    /scratch/marvel.sock  (default)  -
     friend   mrvl://friend-mac     -"
lab
verdict "C-td-5 FAILs while a cluster beyond local is still configured" "RUNG 12 FAIL C-td-5:" 1
named "C-td-5 names the cluster that is left" "friend"
put config.out "     NAME   ADDRESS              IDENTITY
     local  /scratch/marvel.sock  (default)  -"
lab
verdict "12 passes when local is not the current cluster but is the only one" "RUNG 12 PASS" 0
put config.out "boom"
put config.rc 1
lab
verdict "C-td-5 FAILs when marvel config list fails" "RUNG 12 FAIL C-td-5:" 1
put config.out ""
put config.rc 0
lab
verdict "C-td-5 FAILs when marvel config list prints nothing" "RUNG 12 FAIL C-td-5:" 1
put config.out "     NAME   ADDRESS      IDENTITY
*    local  /scratch/marvel.sock  (default)  -"
LABPATH=/usr/bin:/bin lab
verdict "12 FAILs when marvel is not on PATH" "RUNG 12 FAIL C-td:" 1

# The check never acts: no mutating verb appears in its code.
script=$ROOT/lab/check/12-teardown.sh
if [[ -f $script ]]; then
  for verb in "marvel stop" "marvel keys revoke" "remove-cluster" "marvel kill" "marvel delete" "bd close" "rm " "gh " "git push" "git commit"; do
    if grep -v -e '^[[:space:]]*#' -e 'fail C-td' "$script" | grep -q -E -e "(^|[;&|(]|do |then )[[:space:]]*$verb|\\\$\\(.*$verb"; then bad "check 12 runs no [$verb]"; else ok "check 12 runs no [$verb]"; fi
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
  for s in "lab report 12" "collaborator" "lab-keys" "lsof" "teardown-start" "gh api" "lab/state/collaborators" "lab/state/invitations" "marvel stop --teardown" "marvel keys revoke" "marvel config remove-cluster" "just lab check 12"; do
    case $body in *"$s"*) ok "rung 12 names $s" ;; *) bad "rung 12 does not name $s" ;; esac
  done
  # the report comes before the collaborator is removed
  head=${body%%Remove the invited collaborator*}
  case $body in *"Remove the invited collaborator"*) ;; *) bad "rung 12 has a step that removes the invited collaborator" ;; esac
  case $head in *"lab report 12"*) ok "rung 12 puts lab report 12 before the collaborator" ;; *) bad "rung 12 does not put lab report 12 before the collaborator" ;; esac
  left=$(section "Left in place")
  for s in "~/.marvel" "~/lab-run" "bd" "brew" "Remote Login" "Local Network" "pmset -c sleep 0"; do
    case $left in *"$s"*) ok "rung 12 Left in place names $s" ;; *) bad "rung 12 Left in place does not name $s" ;; esac
  done
fi

# --- hygiene --------------------------------------------------------------------
userpath="/Use""rs/"
emdash=$'\xe2\x80\x94'
for f in "$ROOT"/lab/check/12-*.sh "$ROOT"/lab/rung/12-*.md "$ROOT"/lab/test/rung-12-test.sh "$ROOT"/lab/test/stubs12/marvel "$ROOT"/lab/test/stubs12/lsof "$ROOT"/lab/test/stubs12/gh; do
  [[ -f $f ]] || { bad "${f#"$ROOT"/} exists"; continue; }
  if grep -q -e "$userpath" -e "$emdash" "$f"; then bad "${f#"$ROOT"/} has a user path or an em dash"; else ok "${f#"$ROOT"/} has no user path or em dash"; fi
done

printf '\n%s assertions, %s failed\n' "$n" "$fails"
[[ $fails -eq 0 ]] || exit 1
