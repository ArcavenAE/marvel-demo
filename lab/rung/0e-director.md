# Rung 0e: the director shim is the pinned release

Demo: director-install says which release of the director shim is installed.

You: ask the agent to run `director-install --status` and read you the first two lines. Run `just lab check 0e`.

## Tools

- director-install and director-mcp. This kit does not carry them yet, so with no release pinned in lab.lock this rung reads SKIP.

## Expected prompts

- `director-install --status` asks, because it is not on the agent's permission list. Answer yes; it only reports.
