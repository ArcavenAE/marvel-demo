# Rung 9: roll back a manifest, then re-exec the daemon in place

Demo: you move a seat to a second manifest version and back, then replace the daemon's program without stopping the seats.

You: ask the agent to apply workloads/ticker/manifest-v2.toml with `marvel work`, kill the ticker seat so it starts again on v2, then apply manifest.toml and kill it again, so its file shows `v=v2` lines and then `v=v1`. Run `just lab check 09` once: it records a baseline and reports SKIP. Install a newer marvel, run `marvel upgrade --daemon` (or `marvel daemon reexec` from the new binary), then run `just lab check 09` again.

## Tools

- marvel, and a second, newer marvel build. A changed manifest reaches a running seat only at its next start, which is why the seat is killed after each apply.
- `marvel daemon reexec` replaces the daemon in place: the daemon pid, the seat names, their pids and their panes stay the same, and only the version and start time change. It needs a release-stamped build; a development build is refused.
- This rung was run with a scratch daemon re-exec between two stamped builds. The variant on a virtual machine one release behind was not run, because starting the lab-base image needs you at the macOS Setup Assistant.

## Expected prompts

- `marvel work` asks. Answer yes, twice.
- `marvel kill` asks. Answer yes, twice.
- `marvel upgrade --daemon` or `marvel daemon reexec` asks. Answer yes.
