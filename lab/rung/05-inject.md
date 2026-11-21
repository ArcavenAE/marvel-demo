# Rung 5: inject and capture

Demo: you type into a seat's pane from outside, and read the pane back.

You run `marvel inject lab/<seat> "<word>" -e` yourself, with a random word, and write the same word to lab/state/nonce-05. Then ask the agent to run `marvel capture` for the seat and run `just lab check 05`.

## Tools

- marvel, with a running ticker seat from rung 1.
- The agent does not inject: sending keystrokes into a pane is executive privilege and stays your step. The check never runs `marvel inject`.

## Expected prompts

- You run `marvel inject` in your own terminal, so the agent is not asked.
- `marvel capture` does not ask. A shell seat shows the word as typed text, because the terminal echoes it.
- Without lab/state/nonce-05 the check reports SKIP and says what to do.
