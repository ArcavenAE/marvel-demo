# Rung 4: a shift with a handoff

Demo: marvel replaces a seat with a successor that carries on counting from where its predecessor stopped.

You: ask the agent to run `marvel shift lab/ticker --role ticker`, wait for the successor, and show both seats' files. Run `just lab check 04`.

## Tools

- marvel, with the ticker team from rung 1. The ticker's manifest names a handoff file; the successor reads its count once, when it starts.
- The shift starts when the old seat writes its handoff. The old seat may keep ticking for a moment, so one number can appear in both files.

## Expected prompts

- `marvel shift` asks, because it is not on the agent's permission list. Answer yes.
- The command prints that the handoff was requested. The successor appears as generation 2, for example `ticker-ticker-g2-0`, and `marvel events` shows `team.shift-completed`.
