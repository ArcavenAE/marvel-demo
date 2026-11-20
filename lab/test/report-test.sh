#!/usr/bin/env bash
# Tests for `lab/run exec` and for lab/report. Each case builds its own fixture
# tree in a scratch directory, with copies of the real lab/run and lab/report,
# so nothing here reads the real lab.lock or posts anything. The gh used by the
# posting tests is a stub that records its arguments; the real gh is never run.
#
#   env -i HOME="$(mktemp -d)" TMPDIR="$(mktemp -d)" PATH="$PATH" bash lab/test/report-test.sh
#
# Prints `ok` or `not ok` per assertion and exits 1 if any failed.

set -euo pipefail

LABDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REAL_RUN=$LABDIR/run
REAL_REPORT=$LABDIR/report
REAL_VERIFY=$LABDIR/verify-report
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lab-report.XXXXXX")
fails=0
n=0

ok() { n=$((n + 1)); printf 'ok %s %s\n' "$n" "$1"; }
bad() { n=$((n + 1)); fails=$((fails + 1)); printf 'not ok %s %s\n' "$n" "$1"; }
expect() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
expect_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }
expect_not() { case $2 in *"$3"*) bad "$1: [$2] has [$3]" ;; *) ok "$1" ;; esac; }
absent() { if [[ -e $2 ]]; then bad "$1: $2 exists"; else ok "$1"; fi; }

# fixture <name>: a lab tree with copies of lab/run and lab/report; sets FX.
fixture() {
  FX=$WORK/$1
  mkdir -p "$FX/lab/check" "$FX/lab/rung" "$FX/bin"
  cp "$REAL_RUN" "$FX/lab/run"
  chmod +x "$FX/lab/run"
  if [[ -f $REAL_REPORT ]]; then
    cp "$REAL_REPORT" "$FX/lab/report"
    chmod +x "$FX/lab/report"
  fi
  if [[ -f $REAL_VERIFY ]]; then
    cp "$REAL_VERIFY" "$FX/lab/verify-report"
    chmod +x "$FX/lab/verify-report"
  fi
  : >"$FX/lab.lock"
}
# lock: pin every file `lab/run digests` lists, keep the other lock lines.
lock() {
  local keep
  keep=$(grep -v '^digest ' "$FX/lab.lock" || true)
  { [[ -z $keep ]] || printf '%s\n' "$keep"; "$FX/lab/run" digests; } >"$FX/lab.lock.new"
  mv "$FX/lab.lock.new" "$FX/lab.lock"
}
# pin <path>: add a digest line for one file by hand.
pin() {
  local sum
  sum=$(shasum -a 256 "$FX/$1" | cut -d' ' -f1)
  printf 'digest %s %s\n' "$1" "$sum" >>"$FX/lab.lock"
}
# runx <args...>: run lab/run in the fixture; sets OUT and RC.
runx() {
  OUT=$(cd "$FX" && env -i HOME="$FX" TMPDIR="$WORK" PATH="$FX/bin:$PATH" "$FX/lab/run" "$@" 2>&1) && RC=0 || RC=$?
}
tool() { printf '%s\n' '#!/usr/bin/env bash' "$2" >"$FX/lab/$1"; chmod +x "$FX/lab/$1"; }

# ---------------------------------------------------------------- lab/run exec

# E1: a pinned file runs; arguments reach it unsplit and unexpanded, it runs
# from the lab root, and its exit status comes back.
fixture e1
tool tool 'printf "[%s]\n" "$@"; pwd; exit 7'
pin lab/tool
runx exec lab/tool 'a b' '$HOME' '*'
expect_has "exec: runs a pinned file" "$OUT" "[a b]"
expect_has "exec: passes \$HOME through unexpanded" "$OUT" '[$HOME]'
expect_has "exec: passes a star through unexpanded" "$OUT" "[*]"
expect_has "exec: runs from the lab root" "$OUT" "$FX"
expect "exec: returns the file's exit status" "$RC" 7

# E2: a file changed after it was pinned FAILs on its digest and is not run.
fixture e2
tool tool "touch \"$FX/ran\"; echo ran"
pin lab/tool
printf '%s\n' '# edited after the lock' >>"$FX/lab/tool"
runx exec lab/tool
expect_has "exec: a changed file names H-digest" "$OUT" "H-digest"
expect "exec: a changed file exits 1" "$RC" 1
absent "exec: a changed file is not run" "$FX/ran"

# E3: a file with no digest line is not run.
fixture e3
tool tool "touch \"$FX/ran\"; echo ran"
runx exec lab/tool
expect_has "exec: an unpinned file names H-nodigest" "$OUT" "H-nodigest"
expect "exec: an unpinned file exits 1" "$RC" 1
absent "exec: an unpinned file is not run" "$FX/ran"

# E4: no lab.lock at all.
fixture e4
tool tool "touch \"$FX/ran\"; echo ran"
mv "$FX/lab.lock" "$FX/lab.lock.gone"
runx exec lab/tool
expect_has "exec: no lab.lock names H-nolock" "$OUT" "H-nolock"
expect "exec: no lab.lock exits 1" "$RC" 1
absent "exec: no lab.lock runs nothing" "$FX/ran"

# E5: a digest line for a file that is not there.
fixture e5
printf '%s\n' "digest lab/gone 0000000000000000000000000000000000000000000000000000000000000000" >>"$FX/lab.lock"
runx exec lab/gone
expect_has "exec: a pinned but missing file names H-missing" "$OUT" "H-missing"
expect "exec: a pinned but missing file exits 1" "$RC" 1

# E6: paths outside lab/ or spelled oddly are refused, even with a digest line.
fixture e6
printf '%s\n' "touch \"$FX/ran\"" >"$FX/outside.sh"
printf '%s\n' "touch \"$FX/ran\"" >"$FX/lab/tool"
sum=$(shasum -a 256 "$FX/outside.sh" | cut -d' ' -f1)
sum2=$(shasum -a 256 "$FX/lab/tool" | cut -d' ' -f1)
for p in "outside.sh" "./outside.sh" "../outside.sh" "lab/../outside.sh" "lab/./tool" "./lab/tool" \
  "lab//tool" "/etc/hosts" "$FX/lab/tool" "lab/" "lab" "LAB/tool" "lab/tool/" "lab/../lab/tool" \
  "lab/check/../tool" "~/x" 'lab/$HOME' "lab/a b"; do
  printf '%s\n' "digest $p $sum" "digest $p $sum2" >>"$FX/lab.lock"
  runx exec "$p"
  expect "exec: refuses the path [$p] with exit 1" "$RC" 1
  expect_has "exec: says it refuses the path [$p]" "$OUT" "refus"
  absent "exec: the path [$p] is not run" "$FX/ran"
done
runx exec ""
expect "exec: an empty path exits 1" "$RC" 1

# E7: a symlink inside lab/ is refused, even when its target's digest is pinned.
fixture e7
printf '%s\n' "touch \"$FX/ran\"" >"$FX/target.sh"
ln -s ../target.sh "$FX/lab/link"
sum=$(shasum -a 256 "$FX/target.sh" | cut -d' ' -f1)
printf '%s\n' "digest lab/link $sum" >>"$FX/lab.lock"
runx exec lab/link
expect_has "exec: a symlink is refused" "$OUT" "H-link"
expect "exec: a symlink exits 1" "$RC" 1
absent "exec: a symlink is not run" "$FX/ran"

# E8: usage.
fixture e8
runx exec
expect "exec: no path exits 2" "$RC" 2
expect_has "exec: no path prints the usage" "$OUT" "usage:"
runx
expect_has "the usage line lists exec" "$OUT" "exec"

# E9: digests lists lab/report once it exists, and a check still verifies.
fixture e9
printf '%s\n' '#!/usr/bin/env bash' 'echo "RUNG 01 PASS"' >"$FX/lab/check/01-pass.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo stub' >"$FX/lab/report"
runx digests
expect_has "digests lists a check script" "$OUT" "digest lab/check/01-pass.sh "
expect_has "digests lists lab/report" "$OUT" "digest lab/report "
printf '%s\n' '#!/usr/bin/env bash' 'echo stub' >"$FX/lab/verify-report"
runx digests
expect_has "digests lists lab/verify-report, which lab/report runs" "$OUT" "digest lab/verify-report "
rm_report=$FX/lab/report
mv "$rm_report" "$rm_report.gone"
runx digests
expect_not "digests omits lab/report when it is absent" "$OUT" "digest lab/report "

# E10: `lab/run versions` prints one line per version pin and never fails.
fixture e10
printf '%s\n' '#!/bin/sh' 'echo "stubtool 1.0.0 (build 7)"' >"$FX/bin/stubtool"
chmod +x "$FX/bin/stubtool"
printf '%s\n' '#!/bin/sh' 'trap "" TERM' 'while :; do sleep 1; done' >"$FX/bin/slowtool"
chmod +x "$FX/bin/slowtool"
{
  printf '%s\n' 'version stubtool 1.0.0 stubtool --version'
  printf '%s\n' 'version drifted 9.9.9 stubtool --version'
  printf '%s\n' 'version nosuch 1.0.0 nosuchtool --version'
  printf '%s\n' 'version slow 1.0.0 slowtool --version'
} >"$FX/lab.lock"
LAB_VERSION_TIMEOUT=1 runx versions
expect_has "versions: a matching tool" "$OUT" "version stubtool 1.0.0 stubtool 1.0.0 (build 7)"
expect_has "versions: a drifted tool shows what it found" "$OUT" "version drifted 9.9.9 stubtool 1.0.0 (build 7)"
expect_has "versions: a missing tool reads missing" "$OUT" "version nosuch 1.0.0 missing"
expect_has "versions: a silent tool reads no answer" "$OUT" "version slow 1.0.0 no answer"
expect "versions: exits 0 whatever the tools say" "$RC" 0
fixture e10b
runx versions
expect "versions: no lab.lock prints nothing and exits 0" "$OUT|$RC" "|0"

# ------------------------------------------- lab/report never runs unpinned text

# P1: lab/report is a real file, pinned by `lab/run digests`.
if [[ -f $REAL_REPORT ]]; then ok "lab/report exists"; else bad "lab/report exists"; fi

# P2: planted executables and instruction files are never run or sourced.
fixture p2
lock
[[ -f $FX/lab/report ]] || : >"$FX/lab/report"
printf '%s\n' '#!/usr/bin/env bash' "touch \"$FX/marker-helper\"" >"$FX/lab/helper"
chmod +x "$FX/lab/helper"
printf '%s\n' '#!/usr/bin/env bash' "touch \"$FX/marker-helper2\"" >"$FX/lab/helper.sh"
chmod +x "$FX/lab/helper.sh"
printf '%s\n' '# rung 04' "run lab/helper then \$(touch $FX/marker-md) and \`touch $FX/marker-md2\`" >"$FX/lab/rung/04-demo.md"
printf '%s\n' "!touch $FX/marker-claude" "\$(touch $FX/marker-claude2)" >"$FX/lab/CLAUDE.md"
printf '%s\n' "touch $FX/marker-env" >"$FX/lab/.env"
printf '%s\n' '#!/usr/bin/env bash' 'echo "RUNG 04 PASS"' >"$FX/lab/check/04-demo.sh"
lock
runx exec lab/report 04 --nonce ABCDEFGH12345678
expect_has "report: runs for real through exec and prints its header" "$OUT" "LAB REPORT 1"
expect "report: exits 0" "$RC" 0
for m in marker-helper marker-helper2 marker-md marker-md2 marker-claude marker-claude2 marker-env; do
  absent "report: never ran or sourced the planted file ($m)" "$FX/$m"
done

# P3: a trace of every command lab/report runs never names an unpinned lab file.
fixture p3
lock
printf '%s\n' '#!/usr/bin/env bash' 'echo "RUNG 04 PASS"' >"$FX/lab/check/04-demo.sh"
lock
printf '%s\n' '#!/usr/bin/env bash' "touch \"$FX/marker\"" >"$FX/lab/helper"
chmod +x "$FX/lab/helper"
printf '%s\n' 'run lab/helper' >"$FX/lab/rung/04-demo.md"
printf '%s\n' 'run lab/helper' >"$FX/lab/CLAUDE.md"
trace=$FX/trace.txt
(cd "$FX" && env -i HOME="$FX" TMPDIR="$WORK" PATH="$FX/bin:$PATH" SHELLOPTS=xtrace PS4='+T ' \
  bash "$FX/lab/run" exec lab/report 04 --nonce ABCDEFGH12345678 >/dev/null 2>"$trace") || true
if [[ -s $trace ]]; then ok "report: the trace was recorded"; else bad "report: the trace was recorded (empty)"; fi
tr_text=$(cat "$trace" 2>/dev/null || true)
for w in "lab/helper" "rung/" "CLAUDE.md" "marker" ".env"; do
  expect_not "report: the trace never names $w" "$tr_text" "$w"
done
absent "report: the traced run made no marker" "$FX/marker"

# P4: a static scan of the real files: lab/report and every pinned file run or
# source nothing that is not pinned. Flags source and dot commands, eval, and
# bash, sh or exec on a path, and names of unpinned instruction text.
scan_file() {
  local f=$1 line bad_lines=""
  [[ -f $f ]] || { printf 'missing\n'; return; }
  while IFS= read -r line; do
    case $line in
      *'source '*|*'. '*/*|*'. ./'*|*'eval '*|*'bash lab/'*|*'sh lab/'*|*'exec lab/'*|*'rung/'*|*CLAUDE.md*)
        bad_lines="$bad_lines|$line" ;;
    esac
  done < <(grep -v '^[[:space:]]*#' "$f")
  printf '%s\n' "$bad_lines"
}
got=$(scan_file "$REAL_REPORT")
expect "report: lab/report sources, evals and executes no other file" "$got" ""
pinned_extra=""
for f in "$LABDIR"/check/*.sh; do
  [[ -e $f ]] || continue
  r=$(scan_file "$f")
  [[ -z $r ]] || pinned_extra="$pinned_extra ${f##*/}:$r"
done
expect "report: no pinned check sources or executes an unpinned file" "$pinned_extra" ""
# The scanner catches what it should (a control that fails on a planted line).
fixture p4
printf '%s\n' '#!/usr/bin/env bash' 'source lab/helper.sh' >"$FX/scan1"
printf '%s\n' '#!/usr/bin/env bash' 'bash lab/helper.sh' >"$FX/scan2"
printf '%s\n' '#!/usr/bin/env bash' 'cat lab/rung/04-demo.md' >"$FX/scan3"
printf '%s\n' '#!/usr/bin/env bash' '# source lab/helper.sh in a comment' 'echo fine' >"$FX/scan4"
for s in scan1 scan2 scan3; do
  r=$(scan_file "$FX/$s")
  if [[ -n $r ]]; then ok "scan control: $s is flagged"; else bad "scan control: $s is flagged"; fi
done
expect "scan control: a comment and plain code are not flagged" "$(scan_file "$FX/scan4")" ""

# ------------------------------------------------------------ the report text

NONCE=ABCDEFGH12345678

# rfix <name>: a fixture ready for reports: a passing check 04, a stub id and
# hostname with known values, a recording gh, a git repo with an origin.
RFX=0
ghargs() { if [[ -f $FX/gh.args ]]; then tr '\n' ' ' <"$FX/gh.args"; fi; }
rfix() {
  RFX=$((RFX + 1))
  fixture "$1.$RFX"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "RUNG 04 PASS"' >"$FX/lab/check/04-demo.sh"
  printf '%s\n' '#!/bin/sh' '[ "$1" = "-un" ] && echo labuser9 || /usr/bin/id "$@"' >"$FX/bin/id"
  printf '%s\n' '#!/bin/sh' 'if [ "${1:-}" = "-s" ]; then echo lab-host-9; else echo lab-host-9.example.invalid; fi' >"$FX/bin/hostname"
  printf '%s\n' '#!/bin/sh' \
    'printf "%s\n" "$@" >"$(dirname "$0")/../gh.args"' \
    'cat >"$(dirname "$0")/../gh.stdin"' \
    'printf "%s %s\n" "${GH_REPO:-}" "${GH_HOST:-}" >"$(dirname "$0")/../gh.env"' \
    'exit "${GH_STUB_EXIT:-0}"' >"$FX/bin/gh"
  printf '%s\n' '#!/bin/sh' \
    'case "$*" in "--get LocalHostName") echo lab-local-9 ;; "--get ComputerName") echo "Lab Mac 9" ;; *) exit 1 ;; esac' >"$FX/bin/scutil"
  chmod +x "$FX/bin/id" "$FX/bin/hostname" "$FX/bin/gh" "$FX/bin/scutil"
  git init -q "$FX"
  git -C "$FX" remote add origin "${2:-https://github.com/own/lab.git}"
  lock
}
# rep <args...>: lab/run exec lab/report <args>; sets OUT (stdout), ERR, RC.
rep() {
  local errf=$FX/err.txt
  OUT=$(cd "$FX" && env -i HOME="$FX" TMPDIR="$WORK" PATH="$FX/bin:$PATH" ${EXTRA_ENV:-} "$FX/lab/run" exec lab/report "$@" 2>"$errf") && RC=0 || RC=$?
  ERR=$(cat "$errf")
}
# verify <file> [args]: run the real verifier; sets VOUT and VRC.
verify() {
  VOUT=$(bash "$REAL_VERIFY" "$@" 2>&1) && VRC=0 || VRC=$?
}

# R1: the shape, line by line, and the verifier accepts it (C-rep-2).
rfix r1
printf '%s\n' 'version stubtool 1.0.0 stubtool --version' >>"$FX/lab.lock"
printf '%s\n' '#!/bin/sh' 'echo "stubtool 1.0.0"' >"$FX/bin/stubtool"
chmod +x "$FX/bin/stubtool"
printf '%s\n' "workload ticker $(printf 'a%.0s' $(seq 1 64))" >>"$FX/lab.lock"
printf '%s\n' '- expected: Read(./lab/deny-probe) denied by a deny rule' 'prompted once for lab/run check' >"$FX/denials.txt"
rep 04 --nonce "$NONCE" --denials "$FX/denials.txt"
expect "report: exits 0" "$RC" 0
expect "report: line 1 is the header" "$(printf '%s\n' "$OUT" | sed -n 1p)" "LAB REPORT 1"
expect "report: line 2 names the rung" "$(printf '%s\n' "$OUT" | sed -n 2p)" "rung 04"
expect "report: line 3 is the verdict" "$(printf '%s\n' "$OUT" | sed -n 3p)" "RUNG 04 PASS"
expect_has "report: a version line" "$OUT" "version stubtool 1.0.0 stubtool 1.0.0"
expect_has "report: a check digest line marked ok" "$OUT" "digest lab/check/04-demo.sh "
expect_has "report: the report digest line" "$OUT" "digest lab/report "
expect_has "report: a workload line" "$OUT" "workload ticker $(printf 'a%.0s' $(seq 1 64))"
expect_has "report: the nonce line" "$OUT" "nonce $NONCE"
expect_has "report: the denials header" "$OUT" "denials and prompts"
expect_has "report: a denial line gets the dash prefix" "$OUT" "- expected: Read(./lab/deny-probe) denied by a deny rule"
expect_has "report: a denial without a dash gets one" "$OUT" "- prompted once for lab/run check"
expect "report: the last line is the last denial" "$(printf '%s\n' "$OUT" | tail -1)" "- prompted once for lab/run check"
printf '%s\n' "$OUT" >"$FX/r1.txt"
verify "$FX/r1.txt"
expect "C-rep-2: the verifier accepts the report (exit 0)" "$VRC" 0
expect_has "C-rep-2: the verifier says OK and the rung" "$VOUT" "report OK rung 04 PASS"
expect_has "C-rep-2: with no nonce list the nonce is unchecked" "$VOUT" "nonce unchecked"
printf '%s\n' "$OUT" | bash "$REAL_VERIFY" - >/dev/null 2>&1 && ok "C-rep-2: the verifier reads standard input" || bad "C-rep-2: the verifier reads standard input"

# R2: the report has the other three verdict shapes, and the verifier takes each.
rfix r2
printf '%s\n' '#!/usr/bin/env bash' 'echo "RUNG 05 SKIP not granted yet"' >"$FX/lab/check/05-skip.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "RUNG 06 FAIL C-x-6: saw seven, wanted eight"; exit 1' >"$FX/lab/check/06-fail.sh"
lock
for id in 05 06 07; do
  rep "$id" --nonce "$NONCE"
  expect "report: rung $id exits 0 whatever the verdict" "$RC" 0
  printf '%s\n' "$OUT" >"$FX/r2-$id.txt"
  verify "$FX/r2-$id.txt"
  expect "C-rep-2: the verifier accepts rung $id (exit 0)" "$VRC" 0
done
rep 05 --nonce "$NONCE"; expect_has "report: a SKIP verdict with its reason" "$OUT" "RUNG 05 SKIP not granted yet"
rep 06 --nonce "$NONCE"; expect_has "report: a FAIL verdict with its check id" "$OUT" "RUNG 06 FAIL C-x-6: saw seven, wanted eight"
rep 07 --nonce "$NONCE"; expect_has "report: a rung with no script still reports the harness refusal" "$OUT" "RUNG 07 FAIL H-missing:"
# A check changed after it was pinned reports differs, and the verifier accepts that too.
printf '%s\n' '# edited' >>"$FX/lab/check/05-skip.sh"
rep 05 --nonce "$NONCE"
expect_has "report: a changed check reports H-digest" "$OUT" "RUNG 05 FAIL H-digest:"
expect_has "report: a changed check's digest line says differs" "$OUT" "digest lab/check/05-skip.sh "
expect_has "report: differs" "$OUT" " differs"
printf '%s\n' "$OUT" >"$FX/r2-d.txt"
verify "$FX/r2-d.txt"
expect "C-rep-2: the verifier accepts a report with a differing digest" "$VRC" 0

# R3: no workload lines pinned, no denials file.
rfix r3
rep 04 --nonce "$NONCE"
expect_has "report: no workloads pinned says so" "$OUT" "workload none pinned"
expect "report: no denials file ends with none" "$(printf '%s\n' "$OUT" | tail -1)" "none"
printf '%s\n' "$OUT" >"$FX/r3.txt"
verify "$FX/r3.txt"
expect "C-rep-2: the verifier accepts the minimal report" "$VRC" 0
: >"$FX/empty.txt"
rep 04 --nonce "$NONCE" --denials "$FX/empty.txt"
expect "report: an empty denials file ends with none" "$(printf '%s\n' "$OUT" | tail -1)" "none"

# R4: free text is made safe: control characters stripped, lines capped, a
# line cannot forge a section, and the count is bounded.
rfix r4
long=$(printf 'x%.0s' $(seq 1 300))
{
  printf 'esc \033[31mred\033[0m and tab\there and cr\r\n'
  printf '%s\n' "$long"
  printf '%s\n' 'nonce ZZZZZZZZ99999999' 'LAB REPORT 1' 'RUNG 04 PASS' 'workload none pinned' 'denials and prompts'
  for i in $(seq 1 30); do printf 'line %s\n' "$i"; done
} >"$FX/denials.txt"
rep 04 --nonce "$NONCE" --denials "$FX/denials.txt"
expect "report: a messy denials file still exits 0" "$RC" 0
expect_not "report: no escape character survives" "$OUT" "$(printf '\033')"
expect_not "report: no carriage return survives" "$OUT" "$(printf '\r')"
expect_not "report: no tab survives" "$OUT" "$(printf '\t')"
expect_has "report: the visible text of a cleaned line stays" "$OUT" "- esc [31mred[0m and tabhere and cr"
longest=$(printf '%s\n' "$OUT" | awk '{ if (length($0) > m) m = length($0) } END { print m }')
if [[ $longest -le 202 ]]; then ok "report: a long line is capped (longest $longest)"; else bad "report: a long line is capped (longest $longest)"; fi
expect "report: the forged lines are dash-prefixed, so one nonce line only" "$(printf '%s\n' "$OUT" | grep -c '^nonce ')" "1"
expect "report: one header line only" "$(printf '%s\n' "$OUT" | grep -c '^LAB REPORT 1$')" "1"
expect "report: one verdict line only" "$(printf '%s\n' "$OUT" | grep -c '^RUNG ')" "1"
expect "report: at most 20 denial lines plus the omitted note" "$(printf '%s\n' "$OUT" | grep -c '^- ')" "21"
expect_has "report: the omitted note says how many" "$OUT" "- (more lines omitted)"
printf '%s\n' "$OUT" >"$FX/r4.txt"
verify "$FX/r4.txt"
expect "C-rep-2: the verifier accepts the messy report" "$VRC" 0

# R5: the three substitutions (ruling addition A): HOME, user name, host name.
rfix r5
printf '%s\n' '#!/usr/bin/env bash' "echo \"RUNG 04 FAIL C-s-4: saw $FX/state by labuser9 on lab-host-9\"; exit 1" >"$FX/lab/check/04-demo.sh"
lock
{
  printf '%s\n' "denied Read($FX/.ssh/key) for labuser9 on lab-host-9.example.invalid, short name lab-host-9"
  printf '%s\n' "second: $FX and labuser9 again, host lab-host-9.example.invalid"
} >"$FX/denials.txt"
rep 04 --nonce "$NONCE" --denials "$FX/denials.txt"
expect "addition A: exits 0" "$RC" 0
expect_not "addition A: the home directory does not appear" "$OUT" "$FX"
expect_not "addition A: the user name does not appear" "$OUT" "labuser9"
expect_not "addition A: the full host name does not appear" "$OUT" "lab-host-9.example.invalid"
expect_not "addition A: the short host name does not appear" "$OUT" "lab-host-9"
expect_has "addition A: the home directory became ~" "$OUT" "denied Read(~/.ssh/key)"
expect_has "addition A: the user name became <user>" "$OUT" "for <user> on"
expect_has "addition A: the host name became <host>" "$OUT" "on <host>, short name <host>"
expect_has "addition A: a verdict's free text is substituted too" "$OUT" "RUNG 04 FAIL C-s-4: saw ~/state by <user> on <host>"
printf '%s\n' "$OUT" >"$FX/r5.txt"
verify "$FX/r5.txt"
expect "addition A: the verifier still accepts the substituted report" "$VRC" 0
# Words that only contain the user name are not touched.
printf '%s\n' 'mylabuser9 labuser9x labuser9_y' >"$FX/denials.txt"
rep 04 --nonce "$NONCE" --denials "$FX/denials.txt"
expect_has "addition A: a word containing the user name stays" "$OUT" "- mylabuser9 labuser9x labuser9_y"
# The macOS names: LocalHostName (and its .local form) and ComputerName differ
# from hostname and hostname -s, and every one of them becomes <host>.
printf '%s\n' 'bonjour lab-local-9.local, bare lab-local-9, named Lab Mac 9, and lab-local-9x stays' >"$FX/denials.txt"
rep 04 --nonce "$NONCE" --denials "$FX/denials.txt"
expect_not "host forms: the .local name does not appear" "$OUT" "lab-local-9.local"
expect_not "host forms: the ComputerName does not appear" "$OUT" "Lab Mac 9"
expect_has "host forms: the .local name and the bare name both become <host>" "$OUT" "- bonjour <host>, bare <host>, named <host>, and lab-local-9x stays"
# A ComputerName with spaces and an apostrophe is matched as one exact string,
# and no fragment of it leaks.
rfix r5c
printf '%s\n' '#!/bin/sh' 'case "$*" in "--get ComputerName") echo "Pat'"'"'s Lab Mac" ;; *) exit 1 ;; esac' >"$FX/bin/scutil"
printf '%s\n' "owned by Pat's Lab Mac, not Pat's Lab Macintosh" >"$FX/denials.txt"
rep 04 --nonce "$NONCE" --denials "$FX/denials.txt"
expect_has "host forms: a ComputerName with spaces and an apostrophe reads <host> as one string" "$OUT" "- owned by <host>, not Pat's Lab Macintosh"
printf '%s\n' "owned by Pat's Lab Mac" >"$FX/denials.txt"
rep 04 --nonce "$NONCE" --denials "$FX/denials.txt"
expect "host forms: nothing of the ComputerName is left beside <host>" "$(printf '%s\n' "$OUT" | tail -1)" "- owned by <host>"
for frag in "Pat" "'s" "Lab" "Mac"; do
  expect_not "host forms: the fragment [$frag] does not leak" "$(printf '%s\n' "$OUT" | tail -1)" "$frag"
done
# scutil failing or printing nothing is skipped and does not fail the report.
for mode in 'exit 1' 'exit 0' 'echo ""' 'echo oops >&2; exit 2'; do
  rfix r5d
  printf '%s\n' '#!/bin/sh' "$mode" >"$FX/bin/scutil"
  printf '%s\n' 'nothing to hide labuser9 on lab-host-9' >"$FX/denials.txt"
  rep 04 --nonce "$NONCE" --denials "$FX/denials.txt"
  expect "host forms: scutil [$mode] does not fail the report" "$RC" 0
  expect_has "host forms: scutil [$mode] leaves the other forms replaced" "$OUT" "- nothing to hide <user> on <host>"
done
# No scutil at all (not darwin): a PATH with only the tools the report needs.
rfix r5e
mkdir -p "$FX/tools"
for t in bash sh awk tr grep wc cat env git sort cut sed dirname shasum sleep kill uname head tail printf test; do
  p=$(command -v "$t" 2>/dev/null || true)
  [[ -z $p || ! -x $p ]] || ln -s "$p" "$FX/tools/$t"
done
mv "$FX/bin/scutil" "$FX/bin/scutil.gone"
nopath="$FX/bin:$FX/tools"
expect "host forms: the control PATH has no scutil" "$(PATH=$nopath command -v scutil || echo none)" "none"
printf '%s\n' 'nothing to hide labuser9 on lab-host-9' >"$FX/denials.txt"
EXTRA_ENV="PATH=$nopath" rep 04 --nonce "$NONCE" --denials "$FX/denials.txt"
expect "host forms: no scutil at all does not fail the report" "$RC" 0
expect_has "host forms: no scutil at all leaves the other forms replaced" "$OUT" "- nothing to hide <user> on <host>"
# A HOME of / or empty is not substituted (that would rewrite every path).
printf '%s\n' 'see /etc/hosts' >"$FX/denials.txt"
OUT=$(cd "$FX" && env -i HOME=/ TMPDIR="$WORK" PATH="$FX/bin:$PATH" "$FX/lab/run" exec lab/report 04 --nonce "$NONCE" --denials "$FX/denials.txt" 2>&1) && RC=0 || RC=$?
expect_has "addition A: a HOME of / leaves other paths alone" "$OUT" "- see /etc/hosts"

# R6: the dry run prints exactly the bytes --post sends (ruling addition A).
rfix r6
printf '%s\n' 'denied something labuser9' >"$FX/denials.txt"
rep 04 --nonce "$NONCE" --denials "$FX/denials.txt"
printf '%s\n' "$OUT" >"$FX/dry.txt"
rep 04 --nonce "$NONCE" --denials "$FX/denials.txt" --post --issue 7
expect "post: exits 0" "$RC" 0
expect "post: the posted body is the dry-run text, byte for byte" "$( { cat "$FX/gh.stdin" 2>/dev/null || true; } | shasum -a 256 | cut -d' ' -f1)" "$(shasum -a 256 <"$FX/dry.txt" | cut -d' ' -f1)"
expect "post: stdout with --post is the same text" "$OUT" "$(cat "$FX/dry.txt")"
expect "post: gh was called as issue comment, repo pinned to the origin, body from standard input" \
  "$(ghargs)" "issue comment 7 --repo github.com/own/lab --body-file - "

# C-rep-1: the origin guard.
for url in "https://github.com/own/lab.git" "https://github.com/own/lab" "git@github.com:own/lab.git" \
  "git@github.com:own/lab" "ssh://git@github.com/own/lab.git" "https://github.com/own/lab/" "https://github.com/Own-1/lab.repo_2.git"; do
  rfix o-ok "$url"
  rep 04 --nonce "$NONCE" --post --issue 7
  want=$(printf '%s' "$url" | sed -E 's#^(https://|ssh://git@|git@)github\.com[:/]##; s#\.git$##; s#/$##')
  expect "C-rep-1: posts for the origin [$url]" "$(ghargs)" "issue comment 7 --repo github.com/$want --body-file - "
done
for url in "https://gitlab.com/own/lab.git" "https://github.com.evil.example/own/lab.git" "https://evil.example/github.com/own/lab" \
  "git@github.com.evil.example:own/lab.git" "git@gitlab.com:own/lab.git" "https://github.com@evil.example/own/lab" \
  "https://github.com/own/lab/extra" "https://github.com/own" "https://github.com/" "/tmp/own/lab" "file:///tmp/own/lab" \
  "https://github.com/own/lab;touch-x" 'https://github.com/own/$(touch x)' "https://github.com/own/la b" "http://github.com/own/lab.git" \
  "https://GITHUB.com/own/lab.git" "https://github.com:8443/own/lab.git" "https://github.com/own/lab.git?x=1" "github.com/own/lab"; do
  rfix o-bad "$url"
  rep 04 --nonce "$NONCE" --post --issue 7
  expect "C-rep-1: refuses the origin [$url] with exit 1" "$RC" 1
  expect_has "C-rep-1: says it refuses [$url]" "$ERR" "refus"
  absent "C-rep-1: gh is not called for [$url]" "$FX/gh.args"
done
rfix o-none
git -C "$FX" remote remove origin
rep 04 --nonce "$NONCE" --post --issue 7
expect "C-rep-1: a tree with no origin is refused (exit 1)" "$RC" 1
absent "C-rep-1: gh is not called with no origin" "$FX/gh.args"
# Other remotes are never consulted, and env knobs cannot redirect the post.
rfix o-up
git -C "$FX" remote add upstream https://github.com/other/place.git
EXTRA_ENV="GH_REPO=other/place GH_HOST=evil.example" rep 04 --nonce "$NONCE" --post --issue 7
expect "C-rep-1: only the origin is used when an upstream exists" "$(ghargs)" "issue comment 7 --repo github.com/own/lab --body-file - "
expect "C-rep-1: GH_REPO and GH_HOST are not passed to gh" "$(cat "$FX/gh.env" 2>/dev/null)" " "
# There is no flag to name a repo.
rfix o-flag
rep 04 --nonce "$NONCE" --post --issue 7 --repo other/place
expect "C-rep-1: --repo is not an option (exit 2)" "$RC" 2
expect_has "C-rep-1: --repo is reported as unknown" "$ERR" "unknown option"
absent "C-rep-1: gh is not called with --repo" "$FX/gh.args"
rep 04 --nonce "$NONCE" --post --issue 7 -R other/place
expect "C-rep-1: -R is not an option (exit 2)" "$RC" 2
# Posting needs an issue number, and the dry run needs none.
rfix o-iss
rep 04 --nonce "$NONCE" --post
expect "post: --post without --issue exits 2" "$RC" 2
rep 04 --nonce "$NONCE" --post --issue abc
expect "post: a non-numeric issue exits 2" "$RC" 2
rep 04 --nonce "$NONCE" --issue 7
expect "post: --issue without --post exits 2" "$RC" 2
absent "post: none of these called gh" "$FX/gh.args"
rep 04 --nonce "$NONCE"
expect "dry run: needs no issue and no origin check" "$RC" 0
absent "dry run: does not call gh" "$FX/gh.args"
# A failing gh is reported and exits 1.
rfix o-ghfail
EXTRA_ENV="GH_STUB_EXIT=1" rep 04 --nonce "$NONCE" --post --issue 7
expect "post: a failing gh exits 1" "$RC" 1
expect_has "post: a failing gh is reported" "$ERR" "post failed"

# Addition B: a body the verifier rejects is never posted; exit 0 and 3 post.
rfix b1
printf '%s\n' '#!/bin/sh' 'cat >/dev/null' 'exit 1' >"$FX/lab/verify-report"
lock
rep 04 --nonce "$NONCE" --post --issue 7
expect "addition B: a verifier exit 1 blocks the post (exit 1)" "$RC" 1
expect_has "addition B: says the shape check failed" "$ERR" "shape check"
absent "addition B: gh is not called" "$FX/gh.args"
for code in 2 4 127; do
  printf '%s\n' '#!/bin/sh' 'cat >/dev/null' "exit $code" >"$FX/lab/verify-report"
  lock
  rep 04 --nonce "$NONCE" --post --issue 7
  expect "addition B: a verifier exit $code blocks the post" "$RC" 1
  absent "addition B: gh is not called after exit $code" "$FX/gh.args"
done
for code in 0 3; do
  printf '%s\n' '#!/bin/sh' 'cat >/dev/null' "exit $code" >"$FX/lab/verify-report"
  lock
  rep 04 --nonce "$NONCE" --post --issue 7
  expect "addition B: a verifier exit $code lets the post through" "$RC" 0
  expect "addition B: gh is called after exit $code" "$(ghargs)" "issue comment 7 --repo github.com/own/lab --body-file - "
  [[ ! -f $FX/gh.args ]] || mv "$FX/gh.args" "$FX/gh.args.seen"
done
# The verifier is run through the digest check: a changed verifier is not run.
rfix b2
printf '%s\n' '# edited after the lock' >>"$FX/lab/verify-report"
rep 04 --nonce "$NONCE" --post --issue 7
expect "pinned: a changed verifier blocks the post" "$RC" 1
expect_has "pinned: the refusal names the digest" "$ERR" "H-digest"
absent "pinned: gh is not called" "$FX/gh.args"
rfix b3
mv "$FX/lab/verify-report" "$FX/lab/verify-report.gone"
rep 04 --nonce "$NONCE" --post --issue 7
expect "pinned: a missing verifier blocks the post" "$RC" 1
absent "pinned: gh is not called with no verifier" "$FX/gh.args"

# Arguments.
rfix a1
for bad_args in "" "--nonce $NONCE" "04" "04 --nonce" "04 --nonce short" "04 --nonce AB!DEFGH12345678" "04 --nonce $NONCE extra" \
  "4x4 --nonce $NONCE" "all --nonce $NONCE" "../04 --nonce $NONCE" "04 --nonce $NONCE --denials /no/such/file" "04 --bogus"; do
  # shellcheck disable=SC2086
  rep $bad_args
  expect "args: [$bad_args] exits 2" "$RC" 2
done

# C-rep-3: a stale nonce reads as stale (the verifier, with an issued-nonce list).
rfix n1
rep 04 --nonce AAAAAAAA11111111
printf '%s\n' "$OUT" >"$FX/n-old.txt"
rep 04 --nonce BBBBBBBB22222222
printf '%s\n' "$OUT" >"$FX/n-new.txt"
printf '%s\n' AAAAAAAA11111111 BBBBBBBB22222222 >"$FX/issued.txt"
verify "$FX/n-new.txt" --nonces "$FX/issued.txt"
expect "C-rep-3: the newest issued nonce is fresh (exit 0)" "$VRC" 0
expect_has "C-rep-3: and reads fresh" "$VOUT" "nonce fresh"
verify "$FX/n-old.txt" --nonces "$FX/issued.txt"
expect "C-rep-3: an older issued nonce is stale (exit 3)" "$VRC" 3
expect_has "C-rep-3: and reads stale" "$VOUT" "nonce stale"
printf '%s\n' CCCCCCCC33333333 >"$FX/issued2.txt"
verify "$FX/n-new.txt" --nonces "$FX/issued2.txt"
expect "C-rep-3: a nonce that was never issued is unknown (exit 3)" "$VRC" 3
expect_has "C-rep-3: and reads unknown" "$VOUT" "nonce unknown"
: >"$FX/issued3.txt"
verify "$FX/n-new.txt" --nonces "$FX/issued3.txt"
expect "C-rep-3: an empty issued list makes every nonce unknown (exit 3)" "$VRC" 3
printf '\n\nAAAAAAAA11111111\n\nBBBBBBBB22222222\n\n' >"$FX/issued4.txt"
verify "$FX/n-new.txt" --nonces "$FX/issued4.txt"
expect "C-rep-3: blank lines in the issued list are ignored" "$VRC" 0
printf '%s\n' BBBBBBBB22222222 AAAAAAAA11111111 >"$FX/issued5.txt"
verify "$FX/n-new.txt" --nonces "$FX/issued5.txt"
expect "C-rep-3: order decides: the nonce listed first is stale (exit 3)" "$VRC" 3
verify "$FX/n-new.txt" --nonces "$FX/no-such-file"
expect "C-rep-3: an unreadable issued list is an error (exit 2)" "$VRC" 2
# A stale report that is also malformed is invalid first.
sed -e 's/^rung 04$/rung 05/' "$FX/n-old.txt" >"$FX/n-bad.txt"
verify "$FX/n-bad.txt" --nonces "$FX/issued.txt"
expect "C-rep-3: a malformed report is invalid (exit 1), not stale" "$VRC" 1

# C-rep-2, the other side: reports the verifier must refuse.
rfix v1
printf '%s\n' 'version stubtool 1.0.0 stubtool --version' >>"$FX/lab.lock"
printf '%s\n' '#!/bin/sh' 'echo "stubtool 1.0.0"' >"$FX/bin/stubtool"
chmod +x "$FX/bin/stubtool"
printf '%s\n' 'a denied read' >"$FX/denials.txt"
rep 04 --nonce "$NONCE" --denials "$FX/denials.txt"
printf '%s\n' "$OUT" >"$FX/good.txt"
verify "$FX/good.txt"
expect "verifier: the control report is accepted" "$VRC" 0
# mutate <name> <awk program>: write a damaged copy and expect exit 1 and a line number.
mutate_expect() {
  awk "$2" "$FX/good.txt" >"$FX/m-$1.txt"
  verify "$FX/m-$1.txt"
  expect "verifier: $1 is invalid (exit 1)" "$VRC" 1
  expect_has "verifier: $1 names a line" "$VOUT" "INVALID line"
}
mutate_expect "a wrong header version" 'NR==1{print "LAB REPORT 2"; next} {print}'
mutate_expect "a lower case header" 'NR==1{print "lab report 1"; next} {print}'
mutate_expect "a header with trailing text" 'NR==1{print $0 " x"; next} {print}'
mutate_expect "a rung line for another rung" 'NR==2{print "rung 05"; next} {print}'
mutate_expect "a bad rung id" 'NR==2{print "rung 4x4"; next} {print}'
mutate_expect "a verdict for another rung" '/^RUNG /{print "RUNG 05 PASS"; next} {print}'
mutate_expect "a second verdict" '/^RUNG /{print; print; next} {print}'
mutate_expect "a verdict in no known shape" '/^RUNG /{print "RUNG 04 MAYBE"; next} {print}'
mutate_expect "a FAIL without a colon" '/^RUNG /{print "RUNG 04 FAIL no-colon"; next} {print}'
mutate_expect "a SKIP with no reason" '/^RUNG /{print "RUNG 04 SKIP"; next} {print}'
mutate_expect "a digest with a short hash" '/^digest /{sub(/[0-9a-f]{4} /, " "); print; next} {print}'
mutate_expect "a digest with an upper case hash" '/^digest /&&!d{d=1; n=split($0,a," "); print a[1], a[2], toupper(a[3]), a[4]; next} {print}'
mutate_expect "a digest with an unknown state" '/^digest /&&!d{d=1; n=split($0,a," "); print a[1], a[2], a[3], "maybe"; next} {print}'
mutate_expect "a digest line with no state" '/^digest /&&!d{d=1; n=split($0,a," "); print a[1], a[2], a[3]; next} {print}'
mutate_expect "a version line with no name" '/^version /{print "version"; next} {print}'
mutate_expect "a workload with a short hash" '/^workload /{print "workload ticker abc"; next} {print}'
mutate_expect "no nonce line" '/^nonce /{next} {print}'
mutate_expect "a nonce that is too short" '/^nonce /{print "nonce abc"; next} {print}'
mutate_expect "a nonce with a bad character" '/^nonce /{print "nonce AB!DEFGH12345678"; next} {print}'
mutate_expect "two nonce lines" '/^nonce /{print; print; next} {print}'
mutate_expect "no denials header" '/^denials and prompts$/{next} {print}'
mutate_expect "a denials line without a dash" '/^- /{print substr($0,3); next} {print}'
mutate_expect "nothing after the denials header" '/^denials and prompts$/{print; exit} {print}'
mutate_expect "an empty line" 'NR==3{print ""} {print}'
mutate_expect "a stray line at the end" '{print} END{print "extra line"}'
mutate_expect "sections in the wrong order" '/^nonce /{held=$0; next} /^denials and prompts$/{print; print held; next} {print}'
mutate_expect "a tab inside a line" '/^version /{sub(/ /, "\t"); print; next} {print}'
mutate_expect "a carriage return" '/^nonce /{print $0 "\r"; next} {print}'
mutate_expect "a non-ASCII byte" '/^rung /{print $0 "\303\251"; next} {print}'
: >"$FX/m-empty.txt"
verify "$FX/m-empty.txt"
expect "verifier: an empty file is invalid (exit 1)" "$VRC" 1
verify "$FX/no-such-report"
expect "verifier: a missing file is an error (exit 2)" "$VRC" 2
verify
expect "verifier: no file is a usage error (exit 2)" "$VRC" 2
expect_has "verifier: the usage line" "$VOUT" "usage:"
verify "$FX/good.txt" --bogus
expect "verifier: an unknown flag is a usage error (exit 2)" "$VRC" 2

printf '%s checks, %s failed\n' "$n" "$fails"
[[ $fails -eq 0 ]] || exit 1
