# relay

Two shell seats that exchange a message over the bus. It is part (i) of the relay
workload: shell seats and the `nats` command line tool only.

- `pong` listens on `agent.lab.relay.ping`, appends `<session> heard ping <n>` to its own log
  in `${LAB_STATE:-$HOME/lab-run}/relay/`, and answers `pong <n>` on `agent.lab.relay.pong`.
- `ping` publishes `ping <n>` on `agent.lab.relay.ping` every 5 seconds and appends what it
  hears on `agent.lab.relay.pong` to `${LAB_STATE:-$HOME/lab-run}/relay/<session>.log`.

The subjects sit inside `agent.<workspace>.<team>.>` because that is the only space a seat
user may use on the managed bus. Both talk to `RELAY_URL`, which defaults to `NATS_URL` (the
seat's own) and then `nats://127.0.0.1:4222`, with `--no-context`. Credentials come from the
seat's environment: each call reads the file named by `DIRECTOR_NATS_PASS_FILE` and hands the
password to `nats` as `NATS_PASSWORD`, with `DIRECTOR_NATS_USER` as `NATS_USER`, in that one
process's environment. The value is never put on a command line or written to a log. They need
`nats` on `PATH`.

To run the rung again, first delete the team with `marvel delete team lab/relay`, so the old seats are gone before the new ones start.

## Expected lines

After three pings, the log of a seat named `relay-ping-g1-0` holds:

    pong 1
    pong 2
    pong 3

and the log of `relay-pong-g1-0` holds:

    relay-pong-g1-0 heard ping 1
    relay-pong-g1-0 heard ping 2
    relay-pong-g1-0 heard ping 3

## Tests

`python3 -I -B -m unittest discover -s workloads/relay -p 'test_*.py'` (Python 3.11 or newer) runs each
role's script under a stub `nats` and checks the credentials, the subjects and the pong log. No bus is used.

## How these lines were recorded

The lines above are the first three lines of each seat's file from a run of `manifest.toml` itself under a
scratch marvel daemon (build 0.1.0-alpha.20261119, commit a08fc2c) with its managed bus, on a scratch `HOME` and
socket, with no hub. The run was inside a macOS `sandbox-exec` profile that allows network traffic to localhost
only, denies the ports of every listener the host had open, and denies file writes outside a scratch directory.
The profile was checked first: connects to a denied local port and to `192.0.2.1:80` failed inside it with
`Operation not permitted`, a write outside the scratch directory failed the same way, and a connect to an
undenied local port and a write inside the scratch directory worked. The seats ran with the manifest's own
5 second interval and no limits, so the files hold more lines than shown.

What this shows: the subjects, the message shapes, the credentials from the seat's environment, and that `ping`
hears the answers `pong` sends.

What it does not show: that the lines hold on a newcomer's machine. The bus rung reads a message sent with
`nats pub` through a managed bus, and rung 6 checks the seats under marvel.
