# Rung 0d: the bus stays on this machine

Demo: marvel's managed bus listens on localhost only and has no link to a hub.

You: ask the agent to run `marvel bus status` and explain each line. Run `just lab check 0d`.

## Tools

- nats-server 2.14.0 or newer on the daemon's PATH (`brew install nats-server`).
- The bus setting, which you write: put the lines below in `config.yaml` in your marvel home (`~/.marvel` unless `MARVEL_HOME` names another). It sits under `clusters:` and `services:`; a bus entry written at the top of the file is not read at all. Keep the file private (mode 600); `marvel keys doctor --fix` sets the mode.

      clusters:
        - name: local
          services:
            - name: bus
              class: message-bus
              provider: nats-server
              mode: managed
              listen: 127.0.0.1:4222
      current_cluster: local

- A daemon restart after you write it: `marvel stop`, then `marvel daemon &`.
- The `nats` command line tool is needed from the relay rung on, not here. This kit does not yet say how to install it.

## Expected prompts

- `marvel bus status` asks, because it is not on the agent's permission list. Answer yes.
- On a fresh Mac, macOS may ask to let your terminal reach the local network. Allow it; until you answer, the check that the LAN address refuses a connection can pass for the wrong reason.
- If another program already holds port 4222, the bus does not start. Pick another port in `listen`.
