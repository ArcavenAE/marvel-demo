# Rung 6: two seats talk over the managed bus

Demo: a ping seat and a pong seat exchange numbered messages on marvel's own bus, and the pong seat logs each ping it hears.

You: ask the agent to apply workloads/relay/manifest.toml with `marvel work`, then to show `marvel bus status` and the tail of both seats' files. Run `just lab check 06`.

## Tools

- marvel with the managed bus from rung 0d, and the `nats` command line tool on the daemon's PATH.
- The seats share the team user for the bus. What is per seat is the password file named by `DIRECTOR_NATS_PASS_FILE`; the roles read it at each call and hand it to `nats` in the environment. The value is never printed. A seat's subjects stay inside `agent.lab.relay.`.
- No hub is configured, so the bus status leaf line reads `n/a`.

## Expected prompts

- `marvel work` asks. Answer yes.
- `marvel bus status` asks. Answer yes.
- Reading the seats' files asks once. Answer yes. Do not ask the agent to read the password file.
