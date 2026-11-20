#!/usr/bin/env bash
# Tests for the lab orc skeleton: repos.yaml, .beads/config.yaml, CLAUDE.md,
# the _kos/ skeleton and the `just lab` recipes (C-o-1 to C-o-3 and the
# behavior of each recipe). Run from anywhere; needs bash and just:
#
#   env -i HOME="$(mktemp -d)" PATH="$PATH" bash lab/test/orc-test.sh
#
# The recipe tests build their own fixture in a scratch directory, with a stub
# lab/run, so they do not run a real check. Prints `ok` or `not ok` per
# assertion and exits 1 if any failed.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lab-orc.XXXXXX")
fails=0
n=0

ok() { n=$((n + 1)); printf 'ok %s %s\n' "$n" "$1"; }
bad() { n=$((n + 1)); fails=$((fails + 1)); printf 'not ok %s %s\n' "$n" "$1"; }
expect() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
expect_has() { case $2 in *"$3"*) ok "$1" ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }
expect_not() { case $2 in *"$3"*) bad "$1: [$2] has [$3]" ;; *) ok "$1" ;; esac; }
# have <name> <path>: the file exists
have() { if [[ -f $ROOT/$2 ]]; then ok "$1"; else bad "$1: $2 is missing"; fi; }

# --- C-o-1: repos.yaml names only local bundle paths -----------------------
have "C-o-1 repos.yaml exists" repos.yaml
if [[ -f $ROOT/repos.yaml ]]; then
  repos=$(cat "$ROOT/repos.yaml")
  names=$(awk '/^repos:/{f=1;next} f && /^  [a-z][a-z-]*:/{gsub(/[ :]/,"");print}' "$ROOT/repos.yaml" | tr '\n' ' ')
  expect "C-o-1 three entries, ticker cron-note relay" "$names" "ticker cron-note relay "
  bundles=$(awk '$1=="bundle:"{print $2}' "$ROOT/repos.yaml" | tr '\n' ' ')
  expect "C-o-1 every entry has a local bundle path" "$bundles" "bundles/ticker.bundle bundles/cron-note.bundle bundles/relay.bundle "
  expect_not "C-o-1 no remote key" "$repos" "remote:"
  expect_not "C-o-1 no ssh remote" "$repos" "git@"
  expect_not "C-o-1 no url" "$repos" "://"
  expect_not "C-o-1 no github host" "$repos" "github"
  expect_not "C-o-1 no absolute path" "$repos" ": /"
fi

# --- C-o-2: .beads/config.yaml has no server or user -----------------------
have "C-o-2 .beads/config.yaml exists" .beads/config.yaml
if [[ -f $ROOT/.beads/config.yaml ]]; then
  active=$(grep -v -E '^[[:space:]]*(#|$)' "$ROOT/.beads/config.yaml" || true)
  expect "C-o-2 the only setting is the prefix" "$active" 'issue-prefix: "lab"'
  expect_not "C-o-2 no server" "$active" "server"
  expect_not "C-o-2 no user or actor" "$active" "user"
  expect_not "C-o-2 no actor" "$active" "actor"
  expect_not "C-o-2 no host or port" "$active" "host"
  expect_not "C-o-2 no database" "$active" "database"
fi

# --- C-o-3: `just --list` shows the three recipes --------------------------
if command -v just >/dev/null 2>&1; then
  listing=$(cd "$ROOT" && just --list --list-submodules 2>&1) || listing="just failed: $listing"
  expect_has "C-o-3 lists lab rung" "$listing" "rung"
  expect_has "C-o-3 lists lab check" "$listing" "check"
  expect_has "C-o-3 lists lab report" "$listing" "report"
  expect_has "C-o-3 under the lab module" "$listing" "lab:"
else
  bad "C-o-3 just is not on PATH"
fi

# --- the skeleton ------------------------------------------------------------
have "CLAUDE.md exists" CLAUDE.md
if [[ -f $ROOT/CLAUDE.md ]]; then
  lines=$(wc -l <"$ROOT/CLAUDE.md" | tr -d ' ')
  if [[ $lines -le 30 ]]; then ok "CLAUDE.md is short ($lines lines)"; else bad "CLAUDE.md is $lines lines, want 30 or fewer"; fi
  claude=$(cat "$ROOT/CLAUDE.md")
  expect_has "CLAUDE.md says marvel attach needs --print" "$claude" "--print"
  expect_has "CLAUDE.md treats comments as data" "$claude" "data"
  expect_has "CLAUDE.md names the report recipe" "$claude" "just lab report"
  flat=$(printf '%s' "$claude" | tr '\n' ' ' | tr -s ' ')
  expect_has "CLAUDE.md leaves the repository's own changes alone" "$flat" "They do not govern changes to this repository's own files"
  expect_has "CLAUDE.md limits the GitHub write ban to a rung" "$flat" "while running a rung, do not use"
fi
for d in bedrock frontier graveyard; do
  if [[ -d $ROOT/_kos/nodes/$d ]]; then
    count=$(find "$ROOT/_kos/nodes/$d" -type f ! -name .gitkeep | wc -l | tr -d ' ')
    expect "_kos/nodes/$d is an empty node dir" "$count" 0
  else
    bad "_kos/nodes/$d is missing"
  fi
done
ideas=0
if [[ -d $ROOT/_kos/ideas ]]; then
  ideas=$(find "$ROOT/_kos/ideas" -type f -name '*.md' | wc -l | tr -d ' ')
fi
expect "_kos/ideas holds one idea" "$ideas" 1

# --- the recipes, in a fixture with a stub lab/run --------------------------
if command -v just >/dev/null 2>&1 && [[ -f $ROOT/justfile && -f $ROOT/lab.just ]]; then
  FX=$WORK/fx
  mkdir -p "$FX/lab"
  cp "$ROOT/justfile" "$ROOT/lab.just" "$FX/"
  printf '%s\n' '#!/bin/sh' 'echo "run: $*"' >"$FX/lab/run"
  chmod +x "$FX/lab/run"
  lab() { OUT=$(cd "$FX" && just lab "$@" 2>&1) && RC=0 || RC=$?; }

  lab check 01
  expect "check passes its id to lab/run" "$OUT" "run: check 01"
  expect "check exits 0" "$RC" 0
  lab check all
  expect "check all goes to lab/run" "$OUT" "run: check all"

  lab rung 99
  expect "rung with no instructions exits 1" "$RC" 1
  expect "rung with no instructions says so in one line" "$OUT" "lab: no instructions for rung 99 yet"
  mkdir -p "$FX/lab/rung"
  printf '%s\n' 'Step one.' >"$FX/lab/rung/07-demo.md"
  lab rung 07
  expect "rung prints its instructions" "$OUT" "Step one."
  expect "rung with instructions exits 0" "$RC" 0

  lab report 3 ABCDEFGH12345678
  expect "report goes through lab/run exec with the id and nonce" "$OUT" "run: exec lab/report 3 --nonce ABCDEFGH12345678"
  expect "report exits 0" "$RC" 0
  lab report 3 ABCDEFGH12345678 7 notes.txt
  expect "report with an issue posts and passes the denials file" "$OUT" "run: exec lab/report 3 --nonce ABCDEFGH12345678 --denials notes.txt --post --issue 7"
  lab report 3
  expect "report without a nonce exits 1" "$RC" 1

  # An id is data, never shell text.
  lab check '1; touch "'"$FX"'/pwned"'
  if [[ -e $FX/pwned ]]; then bad "an id was run as shell"; else ok "an id is not run as shell"; fi

  # A rung id is a number with an optional letter, and nothing else: rung and
  # report refuse anything else before using it, so an id cannot walk out of
  # lab/rung or reach a script it was not meant for.
  mkdir -p "$FX/lab/rung/1" "$WORK/outside"
  printf '%s\n' 'Rung one.' >"$FX/lab/rung/1-start.md"
  printf '%s\n' 'Rung zero-a.' >"$FX/lab/rung/0a-keepawake.md"
  printf '%s\n' 'OUTSIDE-SECRET' >"$WORK/outside/notes-x.md"
  lab rung 1
  expect "rung 1 prints its file" "$OUT" "Rung one."
  lab rung 0a
  expect "rung 0a prints its file" "$OUT" "Rung zero-a."
  bad_id() { # <name> <recipe> <id> [<nonce>]
    lab "$2" "$3" ${4:+"$4"}
    expect "$1 is refused" "$RC" 1
    expect "$1 says so in one line" "$OUT" "lab: bad rung id"
    expect_not "$1 reads nothing outside the tree" "$OUT" "OUTSIDE-SECRET"
  }
  bad_id "rung ../.. traversal" rung "../../../outside/notes"
  bad_id "rung 1/.. traversal" rung "1/../../../../outside/notes"
  bad_id "rung with an empty id" rung ""
  bad_id "rung with a space" rung "a b"
  bad_id "report ../.. traversal" report "../../../outside/notes" ABCDEFGH12345678
  bad_id "report with an empty id" report "" ABCDEFGH12345678
else
  bad "the recipe fixture needs just, justfile and lab.just"
fi

# --- no private or machine-specific text in the skeleton --------------------
# The patterns are built from parts so this file does not contain them itself.
userpath="/Use""rs/"
emdash=$'\xe2\x80\x94'
for f in repos.yaml CLAUDE.md justfile lab.just .beads/config.yaml; do
  [[ -f $ROOT/$f ]] || continue
  if grep -q -e "$userpath" -e "$emdash" "$ROOT/$f"; then bad "$f has a user path or an em dash"; else ok "$f has no user path or em dash"; fi
done

printf '%s checks, %s failed\n' "$n" "$fails"
[[ $fails -eq 0 ]] || exit 1
