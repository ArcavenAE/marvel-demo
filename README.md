# marvel-demo

Someone who wants to run marvel for their own goal has no safe place to learn it first. This repository is for a small lab kit: exercises with known, predictable work that a newcomer can run on their own machine to see how marvel behaves before relying on it.

Status: the install checks (rungs 0a to 0g) and the three workloads are in. Rungs 1 to 12, the way the kit reaches a newcomer, and the kit build are not built yet. Work lands by PR.

## What is here

- `lab/run`, `lab.lock` and `lab.just`: the check harness. `just lab check N` runs the check for rung N and prints one `RUNG` line. `lab/HARNESS.md` describes the rules.
- `lab/check/` and `lab/rung/`: a check and an instruction file for each install rung, 0a to 0g. `just lab rung N` prints the instructions.
- `lab/report` and `lab/verify-report`: the report for a rung, and the check on that report.
- `.claude/settings.json` and `lab/check-settings`: the permission settings for the agent, and a check that they hold.
- `manifests/keepawake.toml`: a manifest that keeps a macOS host awake while the lab runs.
- `workloads/`: three small workloads for the later rungs (`ticker`, `cron-note`, `relay`), each with a manifest and a README. See `workloads/README.md`.
- `lab/test/`: the tests for the harness, the checks and the report.

## Not built yet

- Rungs 1 to 12: no check or instruction file exists for them.
- Delivery: there is no release, bundle or tarball yet, so this repository is not a way to get the kit.
- The kit build.
