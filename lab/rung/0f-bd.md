# Rung 0f: bd works inside this orc

Demo: bd keeps its work list in this lab, not anywhere else on your machine.

You: ask the agent to run `bd where`, then to create one throwaway issue, show it and close it. Run `just lab check 0f`.

## Tools

- bd, installed and on your PATH. Its `.beads/config.yaml` in this lab sets only the issue prefix.

## Expected prompts

- `bd where` and `bd create` ask. Answer yes.
- `bd show` does not ask. `bd close` asks. Answer yes; the issue is a throwaway.
