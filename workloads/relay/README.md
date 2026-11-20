# relay

Two shell seats that exchange a message over the bus. It is part (i) of the relay
workload: shell seats and the `nats` command line tool only.

- `pong` listens on `lab.relay.ping` and answers `pong <n>` on `lab.relay.pong`.
- `ping` publishes `ping <n>` on `lab.relay.ping` every 5 seconds and appends what it
  hears on `lab.relay.pong` to `${LAB_STATE:-$HOME/lab-run}/relay/<session>.log`.

Both talk to `RELAY_URL`, which defaults to `nats://127.0.0.1:4222`, with `--no-context`
and no credentials file. They need `nats` on `PATH`.

## Expected lines

After three pings, the log of a seat named `lab-ping-g1-0` holds:

    pong 1
    pong 2
    pong 3

## How these lines were recorded

The two loops in `manifest.toml` were run by themselves, not under marvel, against a
scratch `nats-server` (`v2.14.6`) on a random localhost port. The server and both
loops ran under a macOS `sandbox-exec` profile that allows network traffic to localhost
only, denies the ports of every listener the host had open (including 4222), and denies
file writes outside a scratch directory. The profile was checked first: a connect to a
denied local port and a connect to `192.0.2.1:80` both failed inside it with `Operation
not permitted`, a write outside the scratch directory failed the same way, and a
connect to an undenied local port and a write inside the scratch directory worked.
The environment was minimal, with a scratch `HOME` and `TMPDIR`, no `MARVEL_SOCKET`
and no daemon. `RELAY_MAX=3`, `RELAY_INTERVAL=1` and `RELAY_DRAIN=2` stop `ping` after
three messages; the manifest sets none of them. The server and `pong` were stopped by
process group when the run ended.

What this shows: the subjects, the message shapes, and that `ping` hears the answers
`pong` sends.

What it does not show: marvel's managed bus, that marvel starts the two seats, or that
the lines hold on a newcomer's machine. The bus rung reads a message sent with `nats
pub` through a managed bus, and the first-team rungs check the seats under marvel.
