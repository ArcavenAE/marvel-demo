# cron-note

A shell loop that appends one line every 2 minutes. The lab uses it to show a
scheduled role.

Each slot adds one line to `$HOME/.marvel/lab/cron-note/<session>.log`:

    <session> slot=<n> <UTC time>

`manifest.toml` also declares a marvel cadence, `note`, on the schedule
`*/2 * * * *` (UTC). At this build marvel's cadence opens a slot on that schedule
and records it, and `marvel events` shows `cadence.slot-opened`. It does not run
anything or type the prompt into the seat. The loop in the manifest does the
appending, and marvel keeps the role running. Both tick every 2 minutes but they
are not tied to each other.

## Expected lines

A seat named `lab-cron-note-g1-0` after three slots. The time field differs on every
run, so it is shown as `<time>`; each real time reads like `2026-01-01T00:00:00Z`:

    lab-cron-note-g1-0 slot=1 <time>
    lab-cron-note-g1-0 slot=2 <time>
    lab-cron-note-g1-0 slot=3 <time>

Two real lines are two minutes apart, to within the time the loop takes to run.

## How these lines were recorded

The loop in `manifest.toml` was run by itself, not under marvel: `sh -c` with the
manifest's own script, in an empty environment with `MARVEL_SESSION` set by hand, a
scratch `HOME`, no `MARVEL_SOCKET` and no daemon. `CRON_NOTE_MAX=3` and
`CRON_NOTE_INTERVAL=0` stop it after three lines with no wait; the manifest sets
neither. The times were replaced by `<time>` after checking each matches the shape
above.

What this shows: the line shape and the slot counter of the script in the manifest.

What it does not show: the 2-minute spacing, that marvel runs or restarts the
role, or that the cadence is accepted and opens slots. The scheduled-role rung
checks those against a running marvel, and reads `cadence.slot-opened` in
`marvel events`.
