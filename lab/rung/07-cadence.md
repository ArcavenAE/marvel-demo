# Rung 7: a scheduled role opens a slot every two minutes

Demo: marvel's cadence opens a slot on a schedule, and records each one as an event.

You: ask the agent to apply workloads/cron-note/manifest.toml with `marvel work`, wait about four minutes, then run `marvel events --kind cadence.slot-opened`. Run `just lab check 07`.

## Tools

- marvel, with the cron-note team. The check reads marvel's own `cadence.slot-opened` events for the team, not the seat's file lines: two file lines would only prove the loop's sleep.
- Two events about 120 seconds apart pass. The check waits up to 270 seconds for the second.

## Expected prompts

- `marvel work` asks. Answer yes.
- `marvel events` does not ask.
