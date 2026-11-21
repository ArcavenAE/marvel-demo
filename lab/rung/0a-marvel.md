# Rung 0a: marvel is installed

Demo: the agent runs `marvel version` and `marvel doctor` and reads you the output.

You: ask the agent to run both and tell you what it sees. A stage with nothing configured yet shows SKIP, which is expected this early. When you are ready, run `just lab check 0a`.

## Tools

Install these yourself before the agent starts; this kit does not install them for you.

- Homebrew, which asks for the Xcode Command Line Tools on a fresh Mac.
- The marvel tap and formula: `brew tap arcavenae/tap`, then `brew install arcavenae/tap/marvel`. marvel's README says Homebrew 6.0 or later needs the tap trusted first and gives no command, so follow the message Homebrew prints.
- tmux 3.5 or later (`brew install tmux`). marvel runs every session in a tmux pane, and `marvel doctor` warns about an older tmux.
- `marvel daemon &`, run by you in a terminal you keep open. The daemon has to be running for the rungs after this one.
- just, which runs the `just lab` recipes (`brew install just`).
- git, and gh with `gh auth login`, for the report rung at the end of the ladder.
- Claude Code, installed and logged in.

## Expected prompts

The agent's permission list lets it run `marvel get`, `marvel doctor`, `marvel capture` and `marvel events` and the `just lab` recipes without asking. Commands outside this list may ask you first.

- `marvel version` asks. Answer yes; it only prints the version.
- Claude Code may stop at a first-run menu such as "Teach auto mode about your environment?". Its first option, "1. Yes", is pre-selected, so do not press Enter on it; choose "2. Not now". marvel never answers a menu for you. marvel's first-run guide says the wording of this menu is from notes, not a capture, so the menu you see may differ.
