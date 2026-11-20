# ticker

A shell loop with predictable output. It is the first workload the lab ladder runs.

Each tick it adds one line to `${LAB_STATE:-$HOME/lab-run}/ticker/<session>.log`:

    <session> gen=<generation> count=<n> v=<version>

It also rewrites `<session>.handoff.md` in the same directory with its counter and the marker line
`END HANDOFF`. The manifest's `shift.handoff` path is `~/lab-run/ticker/{session}.handoff.md`, so
it matches only while `LAB_STATE` is unset. A successor started with `MARVEL_PREDECESSOR` set reads the
predecessor's handoff file and continues the count.

Files:

- `manifest.toml`: version v1, tick every 5 seconds.
- `manifest-v2.toml`: the same loop, with `TICKER_VERSION=v2` so every line ends `v=v2`. Going from v1 to v2 and back shows in the lines.

## Expected lines

A first seat named `lab-ticker-g1-0` that runs three ticks:

    lab-ticker-g1-0 gen=1 count=1 v=v1
    lab-ticker-g1-0 gen=1 count=2 v=v1
    lab-ticker-g1-0 gen=1 count=3 v=v1

Its handoff file ends:

    count=3
    END HANDOFF

Its successor `lab-ticker-g2-0`, started with `MARVEL_PREDECESSOR=lab-ticker-g1-0`, continues the count in its own log:

    lab-ticker-g2-0 gen=2 count=4 v=v1
    lab-ticker-g2-0 gen=2 count=5 v=v1

With `manifest-v2.toml` the same lines end `v=v2`.

## How these lines were recorded

The loop in `manifest.toml` was run by itself, not under marvel: `sh -c` with the
manifest's own script, in an empty environment with `MARVEL_SESSION` (and
`MARVEL_PREDECESSOR` for the successor) set by hand, a scratch `HOME`, no
`MARVEL_SOCKET` and no daemon. `TICKER_MAX` and `TICKER_INTERVAL=0` stop the loop
after a fixed count with no wait; the manifest sets neither, so a real seat ticks every 5 seconds without end.

What this shows: the script's line shape, its counter, its handoff file, and that the
lines above equal a real run of the script in the manifest.

What it does not show: that marvel starts the seat, that it sets `MARVEL_SESSION` and
`MARVEL_PREDECESSOR` as assumed here, that it scales or shifts the role, or that a
shift reads the handoff file. The ladder rungs for the first team, scale, shift and
rollback check those against a running marvel.

The generation is read from the session name (the part after `-g`), because marvel
sets no separate generation variable.
