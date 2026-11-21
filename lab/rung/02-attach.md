# Rung 2: reach one host with attach

Demo: you open a running seat's own terminal, type a word into it and leave without stopping it.

You: ask the agent to run `marvel attach` for the ticker with `--print`, which prints the tmux command instead of running it. Run that command yourself in your own terminal, type a random word, then detach with Ctrl-b and then d. Write the same word to lab/state/nonce-02 and run `just lab check 02`.

## Tools

- marvel and tmux 3.5 or newer, from rung 0a.
- The agent never runs `marvel attach` without `--print`: attaching takes over a terminal and the command would hang.

## Expected prompts

- `marvel attach` asks, because it is not on the agent's permission list. Answer yes, and only for the `--print` form.
- The check without lab/state/nonce-02 reports SKIP and says what to do. That is the human step, not a failure.
