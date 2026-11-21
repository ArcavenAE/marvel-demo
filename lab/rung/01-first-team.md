# Rung 1: your first team

Demo: marvel runs a team of one small shell seat, the ticker, and the seat writes a numbered line every 5 seconds.

You: ask the agent to apply workloads/ticker/manifest.toml with `marvel work`, then to show the session with `marvel get sessions` and the first lines of the ticker's file. Run `just lab check 01` when the seat is running.

## Tools

- marvel, with its daemon running from rung 0a.
- The ticker workload in workloads/ticker. It writes `<session> gen=<n> count=<n> v=<version>` to `lab-run/ticker/<session>.log` in your home.

## Expected prompts

- `marvel work` asks, because it is not on the agent's permission list. Answer yes.
- `marvel get sessions` does not ask. Reading the ticker's file asks once; answer yes.
