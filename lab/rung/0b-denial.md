# Rung 0b: one denial, on purpose

Demo: this lab keeps one file the agent may not read. You tell the agent beforehand that you are about to ask for it.

You: ask the agent to read lab/deny-probe. It will be refused. Ask the agent to write the refusal, in its own words and with the rule that matched, to lab/state/0b-denial.txt. The report must quote the reason for the denial and say nothing about what the file holds. Then run `just lab check 0b`.

## Tools

- Claude Code, logged in: the denial is its permission system's, so this rung needs the agent session you already have.
- python3, which the check runs as `python3 -I` to read `.claude/settings.json`.

## Expected prompts

- The read of lab/deny-probe is refused, not asked. That is the point of the rung. There is nothing to approve; quote the stated reason.
- Writing lab/state/0b-denial.txt does not ask, because the agent may edit files under lab/.
