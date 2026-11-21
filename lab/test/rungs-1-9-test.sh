#!/usr/bin/env bash
# Tests for the ladder rungs 1 to 9 (lab/check/0[1-9]-*.sh).
# Every rung has a pass case and a negative control: the same check run with
# its condition removed must print `RUNG 0x FAIL C-rx: ...` and exit 1.
#
# The checks talk to marvel, tmux and bd. Here each is a stub on a scratch PATH
# whose answers come from files in a state directory, so no test touches a real
# daemon, the real marvel home or the network. The workload logs the checks read
# are plain files under the fixture's own home. Run from anywhere:
#
#   env -i HOME="$(mktemp -d)" TMPDIR="$(mktemp -d)" PATH="$PATH" \
#     bash lab/test/rungs-1-9-test.sh
#
# Prints `ok` or `not ok` per assertion and exits 1 if any failed.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lab-rungs19.XXXXXX")
fails=0
n=0

ok() { n=$((n + 1)); printf 'ok %s %s\n' "$n" "$1"; }
bad() { n=$((n + 1)); fails=$((fails + 1)); printf 'not ok %s %s\n' "$n" "$1"; }
expect() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
expect_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }
expect_not() { case $2 in *"$3"*) bad "$1: [$2] has [$3]" ;; *) ok "$1" ;; esac; }

# --- the fixture ---------------------------------------------------------------
# fixture <name>: a fresh lab root with the real harness and the real checks 01
# to 09, stub tools on bin/, and a lab.lock that pins every check. FX is the
# lab root, ST the stub state directory, HM the fixture's home, and LOGS the
# directory the workloads write to (the default, ${LAB_STATE:-$HOME/lab-run}).
fixture() {
  FX=$WORK/$1
  ST=$FX/state-stub
  HM=$FX/home
  LOGS=$HM/lab-run
  mkdir -p "$FX/lab/check" "$FX/lab/state" "$FX/bin" "$ST" "$LOGS/ticker" "$LOGS/relay" "$LOGS/cron-note"
  cp "$ROOT/lab/run" "$FX/lab/run"
  chmod +x "$FX/lab/run"
  for f in "$ROOT"/lab/check/0[1-9]-*.sh; do
    [[ -e $f ]] && cp "$f" "$FX/lab/check/"
  done
  cp "$ROOT"/lab/test/stubs19/* "$FX/bin/"
  chmod +x "$FX"/bin/*
  defaults
  relock
}

relock() { LAB_ROOT=$FX "$FX/lab/run" digests >"$FX/lab.lock"; }

# put <file> <text>: write a state file
put() { printf '%s\n' "$2" >"$ST/$1"; }

# seat <name> <role> <state> <pid> <pane> <gen>: one JSON object for marvel get sessions
seat() {
  printf '{"Name":"%s","Workspace":"lab","Team":"%s","Role":"%s","State":"%s","PID":%s,"PaneID":"%s","Generation":%s}' \
    "$1" "${1%%-*}" "$2" "$3" "$4" "$5" "$6"
}
# sessions <object...>: the sessions.json answer, objects joined by commas
sessions() {
  local out="" o
  for o in "$@"; do out=${out:+$out,}$o; done
  put sessions.json "[$out]"
}

TICKER0=ticker-ticker-g1-0
defaults() {
  sessions "$(seat $TICKER0 ticker running 4101 %1 1)"
  put attach.out "lab/$TICKER0 is desk 1
tmux -L marvel-f04cd3dc attach -t %1"
  put tmux.rc 0
  : >"$ST/tmux.calls"
  put capture.out ""
  put bus.out "managed:  true
ready:    yes
leaf:     n/a
url:      nats://127.0.0.1:4222
listen:   127.0.0.1:4222"
  put events.out "TIME      SEV   KIND                 SESSION        MESSAGE"
  put version.out "marvel 1.2.3 (alpha)
daemon  1.2.3 (alpha) commit aaaa111 pid 900 started 2026-11-21T03:40:48Z"
  put bd.list.json "[]"
  put bd.show.json "[]"
}

# lab <id>: run one check through the harness; sets OUT and RC. The caller's
# LAB_WAIT and LAB_WAIT_CADENCE apply.
lab() {
  OUT=$(env -i HOME="$HM" TMPDIR="$WORK" PATH="$FX/bin:/usr/bin:/bin" \
    LAB_ROOT="$FX" LABT_STATE="$ST" LAB_WAIT="${LAB_WAIT:-3}" LAB_WAIT_CADENCE="${LAB_WAIT_CADENCE:-2}" \
    ${PASSFILE:+DIRECTOR_NATS_PASS_FILE="$PASSFILE"} ${PASSFILE:+DIRECTOR_NATS_USER=relay} \
    "$FX/lab/run" check "$1" 2>&1) && RC=0 || RC=$?
}

# verdict <name> <want line prefix> <want rc>
verdict() {
  case $OUT in
    *"$2"*) [[ $RC -eq $3 ]] && ok "$1" || bad "$1: exit $RC, want $3: [$OUT]" ;;
    *) bad "$1: [$OUT] lacks [$2]" ;;
  esac
}

# ticks <file> <session> <gen> <from> <to> <version>: write ticker log lines
ticks() {
  local i
  for ((i = $4; i <= $5; i++)); do printf '%s gen=%s count=%s v=%s\n' "$2" "$3" "$i" "$6" >>"$1"; done
}

# --- 01 first team --------------------------------------------------------------
fixture r01
ticks "$LOGS/ticker/$TICKER0.log" $TICKER0 1 1 3 v1
lab 01
verdict "01 passes with the ticker running and its first line in the README shape" "RUNG 01 PASS" 0
sessions
lab 01
verdict "01 FAILs with no ticker session" "RUNG 01 FAIL C-r1:" 1
sessions "$(seat $TICKER0 ticker pending 0 %1 1)"
lab 01
verdict "01 FAILs when the ticker is not running" "RUNG 01 FAIL C-r1:" 1
sessions "$(seat $TICKER0 ticker running 4101 %1 1)"
printf '%s\n' "hello" >"$LOGS/ticker/$TICKER0.log"
lab 01
verdict "01 FAILs when the first line is not the ticker's shape" "RUNG 01 FAIL C-r1:" 1
: >"$LOGS/ticker/$TICKER0.log"
ticks "$LOGS/ticker/$TICKER0.log" $TICKER0 1 2 3 v1
lab 01
verdict "01 FAILs when a first generation seat does not start at count 1" "RUNG 01 FAIL C-r1:" 1
mv "$LOGS/ticker/$TICKER0.log" "$LOGS/ticker/$TICKER0.gone"
lab 01
verdict "01 FAILs when the ticker file is missing" "RUNG 01 FAIL C-r1:" 1

# --- 02 reach, one host ---------------------------------------------------------
fixture r02
NONCE2=nonce-02-c3a9f1
printf '%s\n' "$NONCE2" >"$FX/lab/state/nonce-02"
put capture.out "ticker output
$NONCE2"
lab 02
verdict "02 passes when socket and desk match and the human's nonce is captured" "RUNG 02 PASS" 0
expect "02 asks tmux about the socket and desk marvel printed" "$(cat "$ST/tmux.calls")" "-L marvel-f04cd3dc has-session -t %1"
if [[ $OUT == *"RUNG 02 PASS"* && ! -e $ST/attach.bare ]]; then ok "02 never runs marvel attach without --print"; else bad "02 ran marvel attach without --print, or did not pass"; fi
mv "$FX/lab/state/nonce-02" "$FX/lab/state/nonce-02.gone"
lab 02
verdict "02 SKIPs, not passes, before the human step has a nonce" "RUNG 02 SKIP" 0
printf '%s\n' "$NONCE2" >"$FX/lab/state/nonce-02"
put capture.out "ticker output only"
lab 02
verdict "02 FAILs when the nonce was not captured from the pane" "RUNG 02 FAIL C-r2:" 1
put capture.out "$NONCE2"
put attach.out "lab/$TICKER0 is desk 9
tmux -L marvel-f04cd3dc attach -t %9"
lab 02
verdict "02 FAILs when the desk marvel attach names is not the session's pane" "RUNG 02 FAIL C-r2:" 1
put attach.out "lab/$TICKER0 is desk 1
tmux -L marvel-f04cd3dc attach -t %1"
put tmux.rc 1
lab 02
verdict "02 FAILs when tmux has no such session" "RUNG 02 FAIL C-r2:" 1
put tmux.rc 0
put attach.out "no such session"
lab 02
verdict "02 FAILs when marvel attach prints no socket and desk" "RUNG 02 FAIL C-r2:" 1

# --- 03 scale -------------------------------------------------------------------
fixture r03
for i in 0 1 2; do ticks "$LOGS/ticker/ticker-ticker-g1-$i.log" ticker-ticker-g1-$i 1 1 3 v1; done
sessions "$(seat ticker-ticker-g1-2 ticker running 4103 %3 1)"
lab 03
verdict "03 passes with three session names in the ticker files and one running" "RUNG 03 PASS" 0
sessions "$(seat ticker-ticker-g1-0 ticker running 4101 %1 1)" "$(seat ticker-ticker-g1-1 ticker running 4102 %2 1)" "$(seat ticker-ticker-g1-2 ticker running 4103 %3 1)"
lab 03
verdict "03 FAILs while three are still running" "RUNG 03 FAIL C-r3:" 1
sessions "$(seat ticker-ticker-g1-2 ticker running 4103 %3 1)"
mv "$LOGS/ticker/ticker-ticker-g1-0.log" "$LOGS/ticker/ticker-ticker-g1-0.gone"
mv "$LOGS/ticker/ticker-ticker-g1-1.log" "$LOGS/ticker/ticker-ticker-g1-1.gone"
lab 03
verdict "03 FAILs when only one session name ever wrote" "RUNG 03 FAIL C-r3:" 1
sessions
lab 03
verdict "03 FAILs when none is running" "RUNG 03 FAIL C-r3:" 1

# --- 04 shift with handoff ------------------------------------------------------
fixture r04
SUCC=ticker-ticker-g2-0
ticks "$LOGS/ticker/$TICKER0.log" $TICKER0 1 1 6 v1
ticks "$LOGS/ticker/$SUCC.log" $SUCC 2 6 7 v1
sessions "$(seat $SUCC ticker running 4201 %2 2)"
put events.out "TIME      SEV   KIND                  SESSION     MESSAGE
03:35:33  info  team.shift-completed  lab/ticker  gen 2 active"
lab 04
verdict "04 passes when the successor continues the predecessor's count" "RUNG 04 PASS" 0
: >"$LOGS/ticker/$SUCC.log"
ticks "$LOGS/ticker/$SUCC.log" $SUCC 2 1 2 v1
lab 04
verdict "04 FAILs when the successor restarts at count 1" "RUNG 04 FAIL C-r4:" 1
: >"$LOGS/ticker/$SUCC.log"
ticks "$LOGS/ticker/$SUCC.log" $SUCC 2 20 21 v1
lab 04
verdict "04 FAILs when the successor's count is not one the predecessor reached" "RUNG 04 FAIL C-r4:" 1
mv "$LOGS/ticker/$SUCC.log" "$LOGS/ticker/$SUCC.gone"
lab 04
verdict "04 FAILs with no second generation file" "RUNG 04 FAIL C-r4:" 1
ticks "$LOGS/ticker/$SUCC.log" $SUCC 2 6 7 v1
put events.out "TIME      SEV   KIND                  SESSION     MESSAGE"
lab 04
verdict "04 FAILs when marvel records no completed shift" "RUNG 04 FAIL C-r4:" 1

# --- 05 inject and capture ------------------------------------------------------
fixture r05
NONCE5=nonce-05-77de0b
printf '%s\n' "$NONCE5" >"$FX/lab/state/nonce-05"
put capture.out "$NONCE5"
lab 05
verdict "05 passes when capture shows the injected nonce" "RUNG 05 PASS" 0
if [[ $OUT == *"RUNG 05 PASS"* && ! -e $ST/inject.called ]]; then ok "05 never runs marvel inject: injecting is the human's step"; else bad "05 ran marvel inject, or did not pass"; fi
put capture.out "other text"
lab 05
verdict "05 FAILs when capture does not show the nonce" "RUNG 05 FAIL C-r5:" 1
mv "$FX/lab/state/nonce-05" "$FX/lab/state/nonce-05.gone"
lab 05
verdict "05 SKIPs, not passes, with no nonce file" "RUNG 05 SKIP" 0
printf '%s\n' "$NONCE5" >"$FX/lab/state/nonce-05"
put capture.out "$NONCE5"
sessions
lab 05
verdict "05 FAILs when no ticker seat is there to capture" "RUNG 05 FAIL C-r5:" 1

# --- 06 bus ---------------------------------------------------------------------
fixture r06
PING=relay-ping-g1-0
PONG=relay-pong-g1-0
relay_ok() {
  sessions "$(seat $PING ping running 5101 %1 1)" "$(seat $PONG pong running 5102 %2 1)"
  printf '%s\n' "$PONG heard ping 1" "$PONG heard ping 2" >"$LOGS/relay/$PONG.log"
  printf '%s\n' "pong 1" "pong 2" >"$LOGS/relay/$PING.log"
}
relay_ok
lab 06
verdict "06 passes on a live exchange read from the pong seat's log" "RUNG 06 PASS" 0
# The seat's password is in its environment's pass file. No report, log or file the rung leaves may hold it.
SECRET6=pw-06-secret-value-31ac
PASSFILE=$FX/seat.pass
printf '%s' "$SECRET6" >"$PASSFILE"
lab 06
grc=0
grep -rqF "$SECRET6" "$FX/lab/state" "$LOGS" "$ST" 2>/dev/null || grc=$?
if [[ $OUT == *"RUNG 06 PASS"* && $OUT != *"$SECRET6"* && $grc -eq 1 ]]; then
  ok "06 holds the seat's password in no report, state file or log"
else
  bad "06 did not pass cleanly, or the password value is in its output or a file: [$OUT]"
fi
unset PASSFILE
put bus.out "managed:  true
ready:    no
leaf:     n/a"
lab 06
verdict "06 FAILs when the bus is not ready" "RUNG 06 FAIL C-r6:" 1
put bus.out "managed:  true
ready:    yes
leaf:     n/a"
sessions "$(seat $PING ping running 5101 %1 1)" "$(seat $PONG pong pending 0 %2 1)"
lab 06
verdict "06 FAILs when the pong seat is not running" "RUNG 06 FAIL C-r6:" 1
relay_ok
: >"$LOGS/relay/$PONG.log"
lab 06
verdict "06 FAILs when the pong seat's log has no ping it heard" "RUNG 06 FAIL C-r6:" 1
relay_ok
printf '%s\n' "pong 1" >"$LOGS/relay/$PING.log"
lab 06
verdict "06 FAILs when the ping seat never saw the answer to the newest ping" "RUNG 06 FAIL C-r6:" 1
relay_ok
touch -t 202001010000 "$LOGS/relay/$PONG.log"
lab 06
verdict "06 FAILs on a stale pong log, so an old exchange is not a pass" "RUNG 06 FAIL C-r6:" 1
for leafval in up unenrolled detached down unknown; do
  relay_ok
  put bus.out "managed:  true
ready:    yes
leaf:     $leafval
listen:   127.0.0.1:4222"
  lab 06
  verdict "06 FAILs when the leaf reads $leafval, not n/a" "RUNG 06 FAIL C-r6:" 1
done

# --- 07 scheduled role ----------------------------------------------------------
fixture r07
slot_events() {
  put events.out "TIME      SEV   KIND                 SESSION        MESSAGE
$1  info  cadence.slot-opened  lab/cron-note  cadence note: slot 1, due 2026-11-21T03:38:00Z
$2  info  cadence.slot-opened  lab/cron-note  cadence note: slot 2, due 2026-11-21T03:40:00Z"
}
slot_events 03:38:01 03:40:01
lab 07
verdict "07 passes on two slot events two minutes apart, with no file line at all: the pass is marvel's events" "RUNG 07 PASS" 0
slot_events 03:38:01 03:39:01
lab 07
verdict "07 FAILs when the slots are one minute apart" "RUNG 07 FAIL C-r7:" 1
put events.out "TIME      SEV   KIND                 SESSION        MESSAGE
03:38:01  info  cadence.slot-opened  lab/cron-note  cadence note: slot 1, due 2026-11-21T03:38:00Z"
lab 07
verdict "07 FAILs, after waiting, with only one slot event" "RUNG 07 FAIL C-r7:" 1
put events.out "TIME      SEV   KIND                 SESSION        MESSAGE
03:38:01  info  cadence.slot-opened  lab/other  cadence note: slot 1
03:40:01  info  cadence.slot-opened  lab/other  cadence note: slot 2"
lab 07
verdict "07 FAILs when the slot events belong to another team" "RUNG 07 FAIL C-r7:" 1
slot_events 23:59:01 00:01:01
lab 07
verdict "07 passes across midnight" "RUNG 07 PASS" 0

# --- 08 bd round trip -----------------------------------------------------------
fixture r08
ISSUE='{"id":"orc-u6d","title":"lab note from ticker seat bd-ticker-ticker-g1-0","status":"%s","labels":["lab","lab-ticker-note"]}'
bdstate() {
  put bd.list.json "[$(printf "$ISSUE" "$1")]"
  put bd.show.json "[$(printf "$ISSUE" "$1")]"
}
bdstate closed
lab 08
verdict "08 passes when the seat's issue reads closed" "RUNG 08 PASS" 0
bdstate open
lab 08
verdict "08 FAILs when the issue is still open" "RUNG 08 FAIL C-r8:" 1
put bd.list.json "[]"
lab 08
verdict "08 FAILs when no seat filed an issue" "RUNG 08 FAIL C-r8:" 1
put bd.list.json '[{"id":"orc-zz1","title":"an unrelated issue","status":"closed"}]'
lab 08
verdict "08 FAILs when the only issue is not the seat's" "RUNG 08 FAIL C-r8:" 1
bdstate closed
lab 08
if [[ $OUT == *"RUNG 08 PASS"* ]] && grep -q -e "--label lab-ticker-note" "$ST/bd.calls" 2>/dev/null; then ok "08 finds the issue by the label marker the bd workload writes, not by its title"; else bad "08 did not pass, or did not ask bd for the lab-ticker-note label: [$OUT]"; fi

# --- 09 rollback and upgrade ----------------------------------------------------
fixture r09
T=$LOGS/ticker/$TICKER0.log
ticks "$T" $TICKER0 1 1 2 v1
ticks "$T" $TICKER0 1 3 4 v2
ticks "$T" $TICKER0 1 5 6 v1
lab 09
verdict "09 records a baseline and SKIPs on the first run" "RUNG 09 SKIP" 0
if [[ -s $FX/lab/state/09-baseline ]]; then ok "09 wrote its baseline"; else bad "09 wrote no baseline"; fi
lab 09
verdict "09 SKIPs, not passes, while the daemon build is unchanged" "RUNG 09 SKIP" 0
put version.out "marvel 1.2.4 (alpha)
daemon  1.2.4 (alpha) commit bbbb222 pid 900 started 2026-11-21T04:10:00Z"
lab 09
verdict "09 passes when the daemon re-exec'd in place and the seats stayed the same" "RUNG 09 PASS" 0
sessions "$(seat $TICKER0 ticker running 4999 %1 1)"
lab 09
verdict "09 FAILs when a seat's process changed across the re-exec" "RUNG 09 FAIL C-r9:" 1
sessions "$(seat $TICKER0 ticker running 4101 %9 1)"
lab 09
verdict "09 FAILs when a seat's pane changed across the re-exec" "RUNG 09 FAIL C-r9:" 1
sessions "$(seat ticker-ticker-g1-7 ticker running 4101 %1 1)"
lab 09
verdict "09 FAILs when a session name changed across the re-exec" "RUNG 09 FAIL C-r9:" 1
sessions "$(seat $TICKER0 ticker running 4101 %1 1)"
put version.out "marvel 1.2.4 (alpha)
daemon  1.2.4 (alpha) commit bbbb222 pid 901 started 2026-11-21T04:10:00Z"
lab 09
verdict "09 FAILs when the daemon pid changed, which is a restart and not a re-exec" "RUNG 09 FAIL C-r9:" 1
put version.out "marvel 1.2.4 (alpha)
daemon  1.2.4 (alpha) commit bbbb222 pid 900 started 2026-11-21T04:10:00Z"
: >"$T"
ticks "$T" $TICKER0 1 1 4 v1
lab 09
verdict "09 FAILs when the ticker log shows no v2 then v1 rollback" "RUNG 09 FAIL C-r9:" 1
: >"$T"
ticks "$T" $TICKER0 1 1 2 v1
ticks "$T" $TICKER0 1 3 4 v2
lab 09
verdict "09 FAILs when the ticker is still on v2" "RUNG 09 FAIL C-r9:" 1

# --- the lock and the instructions ----------------------------------------------
# Every check is pinned in the real lab.lock, and every rung has instructions
# that `just lab rung N` prints, with Tools and Expected prompts sections.
rungfile() { ls "$ROOT"/lab/rung/"$1"-*.md 2>/dev/null | head -1 || true; }
section() { awk -v h="## $2" '$0 == h {on=1; next} /^## /{on=0} on' "$1"; }
for id in 01 02 03 04 05 06 07 08 09; do
  want=$(LAB_ROOT=$ROOT "$ROOT/lab/run" digests | awk -v id="$id" '$2 ~ "lab/check/"id"-" {print $0}')
  if [[ -z $want ]]; then bad "rung $id has a check script"; elif grep -q -F -x "$want" "$ROOT/lab.lock"; then ok "rung $id check is pinned in the real lab.lock"; else bad "rung $id check is not pinned in the real lab.lock"; fi
  md=$(rungfile "$id")
  if [[ -z $md ]]; then bad "rung $id has instructions"; bad "rung $id instructions are printed by just lab rung"; bad "rung $id has a Tools section"; bad "rung $id has an Expected prompts section"; continue; fi
  if [[ -s $md ]] && ! grep -q '^RUNG ' "$md"; then ok "rung $id instructions exist and hold no verdict line"; else bad "rung $id instructions are empty or hold a verdict line"; fi
  if command -v just >/dev/null 2>&1; then
    printed=$(cd "$ROOT" && just lab rung "$id" 2>&1) || printed="just failed"
    if [[ $printed == "$(cat "$md")" ]]; then ok "rung $id instructions are printed by just lab rung"; else bad "rung $id instructions differ from just lab rung output"; fi
  else
    bad "just is not on PATH, so rung $id's printout was not tested"
  fi
  if [[ -n $(section "$md" Tools) ]]; then ok "rung $id has a Tools section"; else bad "rung $id has no Tools section"; fi
  if [[ -n $(section "$md" "Expected prompts") ]]; then ok "rung $id has an Expected prompts section"; else bad "rung $id has no Expected prompts section"; fi
done
# has <rung> <section or ALL> <string...>: the rung file (or one section) names each string
has() {
  local id=$1 sec=$2 f s body
  shift 2
  f=$(rungfile "$id")
  if [[ -z $f ]]; then bad "rung $id text exists"; return; fi
  if [[ $sec == ALL ]]; then body=$(cat "$f"); else body=$(section "$f" "$sec"); fi
  for s in "$@"; do
    case $body in *"$s"*) ok "rung $id $sec names $s" ;; *) bad "rung $id $sec does not name $s" ;; esac
  done
}
has 01 ALL "marvel work" "ticker"
has 02 ALL "marvel attach" "--print" "nonce-02" "detach"
has 03 ALL "marvel scale"
has 04 ALL "marvel shift" "--role ticker" "handoff"
has 05 ALL "marvel inject" "nonce-05" "marvel capture"
has 05 "Expected prompts" "marvel inject"
has 06 ALL "DIRECTOR_NATS_PASS_FILE" "agent.lab.relay" "nats" "marvel work"
has 07 ALL "marvel events" "cadence.slot-opened"
has 08 ALL "bd" "lab-ticker-note"
has 08 "Expected prompts" "bd close"
has 09 ALL "marvel upgrade --daemon" "marvel daemon reexec" "v2"
has 02 "Expected prompts" "marvel attach"
has 03 "Expected prompts" "marvel scale"
has 04 "Expected prompts" "marvel shift"
f05=$(rungfile 05)
case $(section "${f05:-/dev/null}" "Expected prompts") in *"You run"*|*"you run"*) ok "05 makes inject a step you run, not one the agent runs" ;; *) bad "05 does not say inject is a step you run" ;; esac
pinned=$(grep -c '^digest lab/check/0[1-9]-' "$ROOT/lab.lock" || true)
expect "the real lab.lock pins exactly the nine ladder checks" "$pinned" 9
userpath="/Use""rs/"
emdash=$'\xe2\x80\x94'
for f in "$ROOT"/lab/check/0[1-9]-*.sh "$ROOT"/lab/rung/0[1-9]-*.md; do
  [[ -f $f ]] || continue
  if grep -q -e "$userpath" -e "$emdash" "$f"; then bad "${f#"$ROOT"/} has a user path or an em dash"; else ok "${f#"$ROOT"/} has no user path or em dash"; fi
done

printf '\n%s assertions, %s failed\n' "$n" "$fails"
[[ $fails -eq 0 ]] || exit 1
