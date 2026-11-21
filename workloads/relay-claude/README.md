# relay-claude

Two Claude seats that exchange one director message. It is rung 10, part (ii) of the
relay workload; part (i) (`workloads/relay`) uses shell seats and the `nats` command line
tool. This rung is optional, it spends model quota (each seat starts a Claude session and
makes a few requests), and it is not part of the release gate. Skip it if you have not got
the quota to spare.

- `answerer` waits for one director message, replies `pong <n>` once, and stops.
- `asker` sends `ping 1` to `agent://relay-claude/relay-claude-answerer-g1-0`, waits for
  one reply, reports it in one line, and stops.

A session is named `<team>-<role>-g<generation>-<n>`, so the answerer's session is
`relay-claude-answerer-g1-0` and that is its director address in the team `relay-claude`.

To run the rung again, first delete the team with `marvel delete team lab/relay-claude`. A rerun without it is named `-g1-1`, and the asker still sends to the old `-g1-0` address.

## What you need

- the `claude` command, logged in;
- the director shim, `director-mcp`, on your `PATH`. If it lives elsewhere, set
  `DIRECTOR_SHIM_BIN` to its full path in the daemon's environment; the manifest names no path;
- a director bus at `NATS_URL` (default `nats://127.0.0.1:4222`), the same one the bus rung used.

## How the director shim reaches each seat

Each role runs `claude` through a small `sh -c` wrapper. The wrapper builds one JSON value
for the director shim from the seat's own names and ends in

    exec claude -n "$MARVEL_SESSION" --strict-mcp-config --mcp-config '<json>' ...

so the shim entry is in the command line and nowhere else. The roles use no per-directory
entry, and `--strict-mcp-config` means no other entry loads beside it. marvel's own flags
arrive after the script and are passed on unchanged, and the first message marvel composes
arrives as `MARVEL_FIRST_PROMPT` and is passed on as claude's first message. `DIRECTOR_ROLE`
is set in each role's `runtime.env`, because marvel does not set it.

## What you will see

- Each seat asks for plan mode, so Claude asks you to approve every tool call. Approve the
  director send in the asker and the director reply in the answerer; nothing here asks you to
  switch plan mode off, and no flag in the manifest does.
- The first time Claude Code starts, it may stop at a menu titled "Teach auto mode about your
  environment?". "1. Yes" is pre-selected, so do not press Enter on it; answer "2. Not now".
  An unattended seat waits at that menu until someone answers.

## Expected lines

In the asker's pane, after you approve the send and the reply arrives, you see a line that
says the reply was `pong 1`.

## How this was checked

This workload was not run: no seat was started and no model was called. `test_manifest.py`
parses `manifest.toml` offline with Python 3.11 or newer, runs each wrapper once with a
stand-in `claude` that only writes its arguments to a file, and checks that the
`--mcp-config` value is one JSON object naming the director shim and its five variables,
that `--strict-mcp-config` is present, that marvel's flags and first message are passed on,
and that the files name no home path, bypass flag or per-directory entry:

    env -i HOME="$(mktemp -d)" TMPDIR="$(mktemp -d)" PATH="$PATH" python3 -I workloads/relay-claude/test_manifest.py

What that shows: the launcher form. What it does not show: that Claude Code accepts the
value, that the two seats find each other, or the text of the reply.
