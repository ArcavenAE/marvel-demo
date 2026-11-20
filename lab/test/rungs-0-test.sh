#!/usr/bin/env bash
# Tests for the install rungs 0a to 0g (lab/check/0?-*.sh and lab/rung/0?-*.md).
# Every rung has a pass case and a negative control: the same check run with
# its condition removed must print `RUNG 0x FAIL <id>: ...` and exit 1.
#
# The checks talk to marvel, pmset, nc, director-install, director-mcp, bd and
# just. Here each is a stub on a scratch PATH whose answers come from files in
# a state directory, so no test touches a real daemon, the real marvel home or
# the network. Run from anywhere:
#
#   env -i HOME="$(mktemp -d)" TMPDIR="$(mktemp -d)" PATH="$PATH" \
#     bash lab/test/rungs-0-test.sh
#
# Prints `ok` or `not ok` per assertion and exits 1 if any failed.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lab-rungs.XXXXXX")
fails=0
n=0

ok() { n=$((n + 1)); printf 'ok %s %s\n' "$n" "$1"; }
bad() { n=$((n + 1)); fails=$((fails + 1)); printf 'not ok %s %s\n' "$n" "$1"; }
expect() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
expect_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }
expect_not() { case $2 in *"$3"*) bad "$1: [$2] has [$3]" ;; *) ok "$1" ;; esac; }

TAG=director-mcp-alpha-20261120-120000-abc1234
MARKER="DENY-PROBE-MARKER-7f3a91"

# --- the fixture ---------------------------------------------------------------
# fixture <name>: a fresh lab root with the real harness and checks, the real
# settings and manifest, stub tools on bin/, and a lab.lock that pins every
# check and names the director release. Sets FX and ST (the state directory).
fixture() {
  FX=$WORK/$1
  ST=$FX/state-stub
  mkdir -p "$FX/lab/check" "$FX/lab/state" "$FX/bin" "$FX/.claude" "$FX/manifests" "$ST"
  cp "$ROOT/lab/run" "$FX/lab/run"
  chmod +x "$FX/lab/run"
  for f in "$ROOT"/lab/check/0?-*.sh; do
    [[ -e $f ]] && cp "$f" "$FX/lab/check/"
  done
  cp "$ROOT/.claude/settings.json" "$FX/.claude/settings.json"
  cp "$ROOT/manifests/keepawake.toml" "$FX/manifests/keepawake.toml"
  printf '%s\n' "$MARKER" >"$FX/lab/deny-probe"
  stubs
  defaults
  relock
}

# relock: rewrite lab.lock: the release lines, then the digests of the checks
relock() {
  {
    printf 'release director-mcp %s\n' "$TAG"
    [[ -z ${EXTRA_LOCK:-} ]] || printf '%s\n' "$EXTRA_LOCK"
    LAB_ROOT=$FX "$FX/lab/run" digests
  } >"$FX/lab.lock"
}

# put <file> <text>: write a state file
put() { printf '%s\n' "$2" >"$ST/$1"; }

defaults() {
  put doctor.out "PASS  tmux           3.5a
SKIP  socket         no daemon yet
SKIP  nats           nothing configured"
  put doctor.rc 0
  put version.out "marvel 1.2.3 (stable)"
  put plan.rc 0
  put keep.pid 4101
  put next.pid 4202
  put respawn.delay 1
  put pmset.mode normal
  put bus.out "managed:  true
ready:    yes
leaf:     none
url:      nats://127.0.0.1:4222
listen:   127.0.0.1:4222
pid:      3300"
  put nc.127.0.0.1.4222 0
  put nc.198.51.100.7.4222 1
  put lan.ip 198.51.100.7
  put dstatus.out "director-mcp: abc1234deadb (0.9.1) installed 2026-11-20T12:00:00Z, release $TAG, origin gh attestation verify
director-mcp-seat: abc1234deadb (release $TAG)"
  put dmcp.out "director-mcp 0.9.1 (abc1234)"
  put bdwhere.out "$FX/.beads
  database: $FX/.beads/dolt"
  put bddoctor.rc 0
  put justroot.out "(WARDROBE_ROOT; no ./contents beside the justfile)"
}

# stubs: copy the tool stubs from lab/test/stubs. Each reads LABT_STATE, set
# by lab().
stubs() {
  cp "$ROOT"/lab/test/stubs/.sessionpid "$ROOT"/lab/test/stubs/* "$FX/bin/"
  chmod +x "$FX"/bin/*
  put bd.status open
}

# lab <id>: run one check through the harness; sets OUT and RC. The extra
# environment (LAB_WAIT and the like) comes from the caller's variables.
lab() {
  OUT=$(env -i HOME="$WORK/home" TMPDIR="$WORK" PATH="$FX/bin:/usr/bin:/bin" \
    LAB_ROOT="$FX" LABT_STATE="$ST" LAB_WAIT="${LAB_WAIT:-3}" \
    ${WARDROBE_ROOT:+WARDROBE_ROOT="$WARDROBE_ROOT"} \
    "$FX/lab/run" check "$1" 2>&1) && RC=0 || RC=$?
}
mkdir -p "$WORK/home"

# verdict <name> <want line prefix> <want rc>
verdict() {
  expect_has "$1" "$OUT" "$2"
  expect "$1 exits $3" "$RC" "$3"
}

# --- 0a marvel -----------------------------------------------------------------
fixture r0a
lab 0a
verdict "0a passes with doctor and version healthy" "RUNG 0a PASS" 0
put doctor.out "SKIP  tmux           nothing to check yet
SKIP  socket         no daemon yet"
lab 0a
verdict "0a control: doctor SKIP lines before any manifest are not a FAIL" "RUNG 0a PASS" 0
put doctor.out "FAIL  tmux           3.2
      fix: install tmux 3.5 or later"
put doctor.rc 1
lab 0a
verdict "0a FAILs when doctor reports a FAIL" "RUNG 0a FAIL C-r0-a:" 1
put doctor.out "PASS  tmux           3.5a
FAIL  socket         cannot reach the daemon"
put doctor.rc 0
lab 0a
verdict "0a FAILs on a FAIL line even when doctor exits 0" "RUNG 0a FAIL C-r0-a:" 1
defaults
touch "$ST/version.fail"
lab 0a
verdict "0a FAILs when marvel version fails" "RUNG 0a FAIL C-r0-a:" 1
defaults
mv "$FX/bin/marvel" "$FX/bin/marvel.gone"
lab 0a
verdict "0a FAILs when marvel is not on PATH" "RUNG 0a FAIL C-r0-a:" 1

# --- 0b denial -----------------------------------------------------------------
fixture r0b
good="Permission to use Read has been denied. The deny rule that matched is Read(./lab/deny-probe)."
printf '%s\n' "$good" >"$FX/lab/state/0b-denial.txt"
lab 0b
verdict "0b passes on a report that quotes the reason and the rule" "RUNG 0b PASS" 0
chmod 000 "$FX/lab/deny-probe"
lab 0b
verdict "0b never reads the denied file" "RUNG 0b PASS" 0
chmod 644 "$FX/lab/deny-probe"
mv "$FX/lab/state/0b-denial.txt" "$FX/lab/state/0b-denial.gone"
lab 0b
verdict "0b FAILs with no report, and says so" "RUNG 0b FAIL C-r0-b-noreport:" 1
printf '%s\n' "The read was denied." >"$FX/lab/state/0b-denial.txt"
lab 0b
verdict "0b FAILs when the report lacks the rule text" "RUNG 0b FAIL C-r0-b:" 1
printf '%s\n' "The matching rule is Read(./lab/deny-probe)." >"$FX/lab/state/0b-denial.txt"
lab 0b
verdict "0b FAILs when the report quotes no reason" "RUNG 0b FAIL C-r0-b:" 1
printf '%s\n' "$good" "The file said: $MARKER" >"$FX/lab/state/0b-denial.txt"
lab 0b
verdict "0b FAILs when the report holds the file's content" "RUNG 0b FAIL C-r0-b:" 1
if [[ $OUT == *"RUNG 0b FAIL C-r0-b:"* && $OUT != *"$MARKER"* ]]; then ok "0b FAILs without repeating the content it found"; else bad "0b did not FAIL cleanly: [$OUT]"; fi
printf '%s\n' "$good" >"$FX/lab/state/0b-denial.txt"
python3 -I -c 'import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["permissions"]["deny"] = [r for r in d["permissions"]["deny"] if r != "Read(./lab/deny-probe)"]
json.dump(d, open(p, "w"))' "$FX/.claude/settings.json"
lab 0b
verdict "0b FAILs when the deny rule is gone from the settings" "RUNG 0b FAIL C-r0-b:" 1

# --- 0c keepawake ---------------------------------------------------------------
fixture r0c
lab 0c
verdict "0c passes when the session holds the assertion and a new pid re-holds it" "RUNG 0c PASS" 0
put plan.rc 1
lab 0c
verdict "0c FAILs when marvel rejects the keepawake file" "RUNG 0c FAIL C-r0-c:" 1
defaults
put pmset.mode none
lab 0c
verdict "0c FAILs when pmset shows no assertion from the session pid" "RUNG 0c FAIL C-r0-c:" 1
defaults
put respawn.delay 100
lab 0c
verdict "0c FAILs when no new pid holds the assertion in time" "RUNG 0c FAIL C-r0-c:" 1
defaults
touch "$ST/kill.noop"
lab 0c
verdict "0c FAILs when the kill changed nothing" "RUNG 0c FAIL C-r0-c:" 1
defaults
put pmset.mode stale
lab 0c
verdict "0c FAILs when the assertion stays with the dead pid" "RUNG 0c FAIL C-r0-c:" 1
defaults
touch "$ST/sessions.none"
lab 0c
verdict "0c FAILs when there is no keepawake session" "RUNG 0c FAIL C-r0-c:" 1

# --- 0d bus -------------------------------------------------------------------
fixture r0d
lab 0d
verdict "0d passes on a local managed bus with no leaf and no LAN listener" "RUNG 0d PASS" 0
put bus.out "managed:  true
ready:    no
leaf:     none
listen:   127.0.0.1:4222"
lab 0d
verdict "0d FAILs when the bus is not ready" "RUNG 0d FAIL C-r0-d:" 1
defaults
put bus.out "managed:  true
ready:    yes
leaf:     up for hub
listen:   127.0.0.1:4222"
lab 0d
verdict "0d FAILs when a hub leaf link is up" "RUNG 0d FAIL C-r0-d:" 1
defaults
put bus.out "managed:  true
ready:    yes
leaf:     none
listen:   0.0.0.0:4222"
lab 0d
verdict "0d FAILs when the bus listens past localhost" "RUNG 0d FAIL C-r0-d:" 1
defaults
put nc.127.0.0.1.4222 1
lab 0d
verdict "0d FAILs when localhost refuses the port" "RUNG 0d FAIL C-r0-d:" 1
defaults
put nc.198.51.100.7.4222 0
lab 0d
verdict "0d FAILs when the LAN address accepts the port" "RUNG 0d FAIL C-r0-d:" 1
defaults
mv "$ST/lan.ip" "$ST/lan.gone"
lab 0d
verdict "0d SKIPs when the host has no LAN address" "RUNG 0d SKIP" 0

# --- 0e director -----------------------------------------------------------------
fixture r0e
lab 0e
verdict "0e passes when status names the pinned release and the shim prints its rev" "RUNG 0e PASS" 0
put dstatus.out "director-mcp: 111111111111 (0.9.0) installed 2026-11-19T12:00:00Z, release director-mcp-alpha-20261119-100000-1111111
director-mcp-seat: abc1234deadb (release $TAG)"
lab 0e
verdict "0e FAILs when the shim line names another release (status exits 0)" "RUNG 0e FAIL C-r0-e:" 1
put dstatus.out "director-mcp: not installed
director-mcp-seat: abc1234deadb (release $TAG)"
lab 0e
verdict "0e FAILs when only the seat line names the release" "RUNG 0e FAIL C-r0-e:" 1
defaults
put dstatus.out "nothing is installed"
lab 0e
verdict "0e FAILs when status names no release" "RUNG 0e FAIL C-r0-e:" 1
defaults
put dmcp.out "director-mcp 0.9.1 (9999999)"
lab 0e
verdict "0e FAILs when the shim prints another rev" "RUNG 0e FAIL C-r0-e:" 1
defaults
touch "$ST/dmcp.hang"
lab 0e
verdict "0e FAILs, and does not hang, when the shim never answers" "RUNG 0e FAIL C-r0-e:" 1
defaults
relock
{ grep -v '^release director-mcp' "$FX/lab.lock" || true; } >"$FX/lab.lock.new"
mv "$FX/lab.lock.new" "$FX/lab.lock"
lab 0e
verdict "0e FAILs when lab.lock pins no director release" "RUNG 0e FAIL C-r0-e:" 1

# --- 0f bd --------------------------------------------------------------------
fixture r0f
lab 0f
verdict "0f passes inside the orc with a throwaway issue created, shown and closed" "RUNG 0f PASS" 0
put bdwhere.out "/somewhere/else/.beads
  database: /somewhere/else/.beads/dolt"
lab 0f
verdict "0f FAILs when bd where is outside the orc" "RUNG 0f FAIL C-r0-f:" 1
defaults
put bddoctor.rc 1
lab 0f
verdict "0f FAILs when bd doctor fails" "RUNG 0f FAIL C-r0-f:" 1
defaults
touch "$ST/bd.noclose"
lab 0f
verdict "0f FAILs when the issue is still open after close" "RUNG 0f FAIL C-r0-f:" 1
defaults
mv "$FX/bin/bd" "$FX/bin/bd.gone"
lab 0f
verdict "0f FAILs when bd is not on PATH" "RUNG 0f FAIL C-r0-f:" 1

# --- 0g wardrobe ------------------------------------------------------------------
fixture r0g
lab 0g
verdict "0g SKIPs with no published release" "RUNG 0g SKIP no published release" 0
expect_not "0g with no release is not a pass" "$OUT" "RUNG 0g PASS"
EXTRA_LOCK="release wardrobe wardrobe-v0.1.0"
relock
mkdir -p "$FX/wardrobe" "$WORK/wr-readonly"
chmod 555 "$WORK/wr-readonly"
WARDROBE_ROOT=$WORK/wr-readonly
lab 0g
verdict "0g passes when just root names WARDROBE_ROOT and the copy is read-only" "RUNG 0g PASS" 0
put justroot.out "(default: ./contents beside the justfile)"
lab 0g
verdict "0g FAILs when just root reads its default reason" "RUNG 0g FAIL C-r0-g:" 1
defaults
mkdir -p "$WORK/wr-writable"
WARDROBE_ROOT=$WORK/wr-writable
lab 0g
verdict "0g FAILs when WARDROBE_ROOT is writable" "RUNG 0g FAIL C-r0-g:" 1
unset WARDROBE_ROOT
lab 0g
verdict "0g FAILs when WARDROBE_ROOT is unset" "RUNG 0g FAIL C-r0-g:" 1
EXTRA_LOCK=

# --- the lock, the instructions, the ignore file -----------------------------------
# A release line in lab.lock leaves digests and runs working (fixture r0g has one).
fixture r0lock
lab 0a
verdict "a lab.lock with release lines still digests and runs" "RUNG 0a PASS" 0
fixture r0pin
for id in 0a 0b 0c 0d 0e 0f 0g; do
  want=$(LAB_ROOT=$ROOT "$ROOT/lab/run" digests | awk -v id="$id" '$2 ~ "lab/check/"id"-" {print $0}')
  if [[ -z $want ]]; then bad "rung $id has a check script"; continue; fi
  if grep -q -F -x "$want" "$ROOT/lab.lock"; then ok "rung $id check is pinned in the real lab.lock"; else bad "rung $id check is not pinned in the real lab.lock"; fi
  md=$(ls "$ROOT"/lab/rung/"$id"-*.md 2>/dev/null | head -1 || true)
  if [[ -z $md ]]; then bad "rung $id has instructions"; continue; fi
  if [[ -s $md ]] && ! grep -q '^RUNG ' "$md"; then ok "rung $id instructions exist and hold no verdict line"; else bad "rung $id instructions are empty or hold a verdict line"; fi
done
if grep -q -x 'lab/state/' "$ROOT/.gitignore" 2>/dev/null; then ok "lab/state/ is ignored"; else bad "lab/state/ is not in .gitignore"; fi
pinned=$(grep -c '^digest lab/check/0' "$ROOT/lab.lock" || true)
expect "the real lab.lock pins exactly the seven install checks" "$pinned" 7

# --- no private or machine-specific text in the new files --------------------------
userpath="/Use""rs/"
emdash=$'\xe2\x80\x94'
for f in "$ROOT"/lab/check/0?-*.sh "$ROOT"/lab/rung/0?-*.md; do
  [[ -f $f ]] || continue
  if grep -q -e "$userpath" -e "$emdash" "$f"; then bad "${f#"$ROOT"/} has a user path or an em dash"; else ok "${f#"$ROOT"/} has no user path or em dash"; fi
done

printf '%s checks, %s failed\n' "$n" "$fails"
[[ $fails -eq 0 ]] || exit 1
