#!/usr/bin/env bash
# Tests for lab/run. Each case builds its own fixture tree in a scratch
# directory with stub checks, so nothing here touches the real lab.lock or
# lab/check. Run from anywhere:
#
#   env -i HOME="$(mktemp -d)" PATH="$PATH" bash lab/test/harness-test.sh
#
# Prints `ok` or `not ok` per assertion and exits 1 if any failed.

set -euo pipefail

RUN=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/run
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lab-harness.XXXXXX")
fails=0
n=0

ok() { n=$((n + 1)); printf 'ok %s %s\n' "$n" "$1"; }
bad() { n=$((n + 1)); fails=$((fails + 1)); printf 'not ok %s %s\n' "$n" "$1"; }

# expect <name> <got> <want>
expect() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
# expect_has <name> <text> <needle>
expect_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }
expect_not() { case $2 in *"$3"*) bad "$1: [$2] has [$3]" ;; *) ok "$1" ;; esac; }

# Fixture helpers. `fixture <name>` makes an empty tree and sets FX to it.
fixture() {
  FX=$WORK/$1
  mkdir -p "$FX/lab/check" "$FX/bin"
  : >"$FX/lab.lock"
}
# check <file> <body>: write lab/check/<file>
check() { printf '%s\n' "$2" >"$FX/lab/check/$1"; }
# lock: record the digests of the scripts as they are now, keep other lines
lock() {
  local keep
  keep=$(grep -v '^digest ' "$FX/lab.lock" || true)
  { [[ -z $keep ]] || printf '%s\n' "$keep"; LAB_ROOT=$FX "$RUN" digests; } >"$FX/lab.lock.new"
  mv "$FX/lab.lock.new" "$FX/lab.lock"
}
# lab <args...>: run the harness on the fixture; sets OUT and RC
lab() {
  OUT=$(LAB_ROOT=$FX PATH="$FX/bin:$PATH" "$RUN" "$@" 2>&1) && RC=0 || RC=$?
}

# C-h-1: a passing and a failing stub print the two shapes and exit 0 and 1.
fixture c-h-1
check 01-pass.sh 'echo "RUNG 01 PASS"'
check 02-fail.sh 'echo "RUNG 02 FAIL C-stub-2: saw seven, wanted eight"; exit 1'
lock
lab check 01
expect "C-h-1 pass prints the PASS shape" "$OUT" "RUNG 01 PASS"
expect "C-h-1 pass exits 0" "$RC" 0
lab check 02
expect "C-h-1 fail prints the FAIL shape" "$OUT" "RUNG 02 FAIL C-stub-2: saw seven, wanted eight"
expect "C-h-1 fail exits 1" "$RC" 1

# C-h-2: a changed check script FAILs on its digest and is not run.
fixture c-h-2
check 01-pass.sh "touch \"$FX/ran\"; echo \"RUNG 01 PASS\""
lock
printf '%s\n' '# edited after the lock' >>"$FX/lab/check/01-pass.sh"
lab check 01
expect_has "C-h-2 names the digest failure" "$OUT" "RUNG 01 FAIL H-digest:"
expect "C-h-2 exits 1" "$RC" 1
if [[ -e $FX/ran ]]; then bad "C-h-2 changed script was run"; else ok "C-h-2 changed script was not run"; fi

# C-h-3: version drift WARNs and exits 0; a matching version is silent.
fixture c-h-3
printf '%s\n' '#!/bin/sh' 'echo "stubtool 1.0.0"' >"$FX/bin/stubtool"
chmod +x "$FX/bin/stubtool"
check 01-pass.sh 'echo "RUNG 01 PASS"'
printf '%s\n' 'version stubtool 9.9.9 stubtool --version' >>"$FX/lab.lock"
lock
lab check 01
expect_has "C-h-3 warns on drift" "$OUT" "WARN version stubtool: lock 9.9.9, found stubtool 1.0.0"
expect_has "C-h-3 still passes" "$OUT" "RUNG 01 PASS"
expect "C-h-3 exits 0" "$RC" 0
printf '%s\n' 'version stubtool 1.0.0 stubtool --version' >"$FX/lab.lock"
lock
lab check 01
expect_not "C-h-3 matching version is silent" "$OUT" "WARN"
printf '%s\n' 'version nosuchtool 1.0.0 nosuchtool --version' >"$FX/lab.lock"
lock
lab check 01
expect_has "C-h-3 a missing tool warns" "$OUT" "WARN version nosuchtool: lock 1.0.0, not found"
expect "C-h-3 a missing tool exits 0" "$RC" 0

# check all: order, stop at the first FAIL, skips are not passes.
fixture all-order
check 10-late.sh "echo ten >>\"$FX/log\"; echo \"RUNG 10 PASS\""
check 02-second.sh "echo two >>\"$FX/log\"; echo \"RUNG 02 PASS\""
check 0a-first.sh "echo zero-a >>\"$FX/log\"; echo \"RUNG 0a PASS\""
check 01-one.sh "echo one >>\"$FX/log\"; echo \"RUNG 01 SKIP not granted\""
lock
lab check all
expect "all runs in number then letter order" "$(tr '\n' ' ' <"$FX/log")" "zero-a one two ten "
expect_has "all counts a skip apart from passes" "$OUT" "LAB check all: 3 pass, 1 skip"
expect "all exits 0 when nothing fails" "$RC" 0

fixture all-stop
check 01-ok.sh 'echo "RUNG 01 PASS"'
check 02-bad.sh 'echo "RUNG 02 FAIL C-stop-2: broke"; exit 1'
check 03-never.sh "touch \"$FX/ran\"; echo \"RUNG 03 PASS\""
lock
lab check all
expect_has "all stops at the first FAIL" "$OUT" "LAB check all: 1 pass, 0 skip, stopped at 02"
expect "all exits 1 on a FAIL" "$RC" 1
if [[ -e $FX/ran ]]; then bad "all ran a check after the FAIL"; else ok "all ran nothing after the FAIL"; fi

fixture all-empty
lab check all
expect "all with no checks exits 1" "$RC" 1

# The harness refuses what it cannot trust.
fixture h-trust
check 01-liar.sh 'echo "RUNG 01 PASS"; exit 1'
check 02-silent.sh 'echo "no verdict here"'
check 03-twice.sh 'echo "RUNG 03 PASS"; echo "RUNG 03 PASS"'
check 04-shape.sh 'echo "RUNG 04 FAIL no-colon"; exit 1'
check 05-unpinned.sh 'echo "RUNG 05 PASS"'
lock
grep -v 'lab/check/05-' "$FX/lab.lock" >"$FX/lab.lock.new" && mv "$FX/lab.lock.new" "$FX/lab.lock"
lab check 01; expect_has "PASS with exit 1 is a mismatch" "$OUT" "RUNG 01 FAIL H-mismatch:"
lab check 02; expect_has "no RUNG line is a noverdict" "$OUT" "RUNG 02 FAIL H-noverdict:"
lab check 03; expect_has "two RUNG lines is a noverdict" "$OUT" "RUNG 03 FAIL H-noverdict:"
lab check 04; expect_has "a malformed FAIL is a shape failure" "$OUT" "RUNG 04 FAIL H-shape:"
lab check 05; expect_has "a script with no digest line FAILs" "$OUT" "RUNG 05 FAIL H-nodigest:"
lab check 09; expect_has "an id with no script FAILs" "$OUT" "RUNG 09 FAIL H-missing:"

# The verdict and the exit status must agree for FAIL and SKIP as well as PASS.
fixture h-exit
check 01-fail-zero.sh 'echo "RUNG 01 FAIL C-exit-1: seen"'
check 02-fail-two.sh 'echo "RUNG 02 FAIL C-exit-2: seen"; exit 2'
check 03-skip-one.sh 'echo "RUNG 03 SKIP not granted"; exit 1'
lock
lab check 01
expect_has "FAIL with exit 0 is a mismatch" "$OUT" "RUNG 01 FAIL H-mismatch:"
expect "FAIL with exit 0 exits 1" "$RC" 1
lab check 02
expect_has "FAIL with exit 2 is a mismatch" "$OUT" "RUNG 02 FAIL H-mismatch:"
lab check 03
expect_has "SKIP with exit 1 is a mismatch" "$OUT" "RUNG 03 FAIL H-mismatch:"
expect "SKIP with exit 1 exits 1" "$RC" 1
expect_not "SKIP with exit 1 is not reported as a skip" "$OUT" "RUNG 03 SKIP"

# Two scripts for one id: refuse, and run neither.
fixture h-ambiguous
check 01-a.sh "touch \"$FX/ran-a\"; echo \"RUNG 01 PASS\""
check 01-b.sh "touch \"$FX/ran-b\"; echo \"RUNG 01 PASS\""
lock
lab check 01
expect_has "two scripts for one id is ambiguous" "$OUT" "RUNG 01 FAIL H-ambiguous:"
expect "ambiguous exits 1" "$RC" 1
if [[ -e $FX/ran-a || -e $FX/ran-b ]]; then bad "ambiguous ran a script"; else ok "ambiguous ran neither script"; fi

# A version command that never answers must not hang the run.
fixture c-timeout
printf '%s\n' '#!/bin/sh' 'exec sleep 30' >"$FX/bin/hangtool"
chmod +x "$FX/bin/hangtool"
check 01-pass.sh 'echo "RUNG 01 PASS"'
printf '%s\n' 'version hangtool 1.0.0 hangtool --version' >>"$FX/lab.lock"
lock
start=$SECONDS
LAB_VERSION_TIMEOUT=1 lab check 01
elapsed=$((SECONDS - start))
expect_has "a hung version command WARNs" "$OUT" "WARN version hangtool: lock 1.0.0, no answer in 1s"
expect_has "a hung version command does not stop the check" "$OUT" "RUNG 01 PASS"
expect "a hung version command exits 0" "$RC" 0
if [[ $elapsed -lt 10 ]]; then ok "the run ended within 10s (took ${elapsed}s)"; else bad "the run took ${elapsed}s"; fi

# A version command that ignores TERM is stopped too.
fixture c-stubborn
printf '%s\n' '#!/bin/sh' 'trap "" TERM' 'while :; do sleep 1; done' >"$FX/bin/stubborn"
chmod +x "$FX/bin/stubborn"
check 01-pass.sh 'echo "RUNG 01 PASS"'
printf '%s\n' 'version stubborn 1.0.0 stubborn --version' >>"$FX/lab.lock"
lock
start=$SECONDS
LAB_VERSION_TIMEOUT=1 lab check 01
elapsed=$((SECONDS - start))
expect_has "a version command that ignores TERM WARNs" "$OUT" "WARN version stubborn: lock 1.0.0, no answer in 1s"
expect "a version command that ignores TERM exits 0" "$RC" 0
if [[ $elapsed -lt 10 ]]; then ok "the run ended within 10s (took ${elapsed}s)"; else bad "the run took ${elapsed}s"; fi
expect_not "no job notice leaks into the output" "$OUT" "Terminated"

fixture h-nolock
check 01-pass.sh 'echo "RUNG 01 PASS"'
mv "$FX/lab.lock" "$FX/lab.lock.gone"
lab check 01
expect_has "no lab.lock FAILs" "$OUT" "RUNG 01 FAIL H-nolock:"

printf '%s checks, %s failed\n' "$n" "$fails"
[[ $fails -eq 0 ]] || exit 1
