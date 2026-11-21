# Rung 3: scale from one to three and back

Demo: one command makes the ticker three seats, and another brings it back to one.

You: ask the agent to run `marvel scale lab/ticker --role ticker --replicas 3`, show the three sessions, then scale back to 1. Run `just lab check 03`.

## Tools

- marvel, with the ticker team from rung 1.
- The oldest seats go first when scaling down, so the seat that remains is a newer one. Its name differs from the one you started with.

## Expected prompts

- Each `marvel scale` asks, because it is not on the agent's permission list. Answer yes.
- The check passes when at least three seat names have written ticker files and exactly one seat is running.
