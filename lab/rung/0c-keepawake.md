# Rung 0c: marvel keeps the machine awake

Demo: marvel runs a small session that holds a sleep assertion, and starts it again when it dies.

You: ask the agent to apply manifests/keepawake.toml with marvel and show you the session. Then ask it to stop that session and watch it come back. Run `just lab check 0c` when it has.

## Tools

- marvel, with its daemon running from rung 0a.
- caffeinate, which macOS provides at /usr/bin/caffeinate. The manifest runs it with `-i -s`, so it holds off idle sleep, and system sleep on AC power.
- pmset, which macOS provides, is what the check reads for the sleep assertion.

## Expected prompts

- Applying the manifest asks, because `marvel work` is not on the agent's permission list. Answer yes.
- `marvel kill` asks, because it is not on the list either. Answer yes; the session should come back on its own within about 30 seconds.
- `marvel get sessions` does not ask.
- This keeps the machine from idle sleep only while the session runs. It does not stop a lid-closed laptop from sleeping.
