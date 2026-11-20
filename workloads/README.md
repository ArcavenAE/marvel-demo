# Workloads

Three small workloads the lab ladder runs. Each directory holds a marvel manifest and
a README with the exact lines a passing run prints and how those lines were recorded.

| directory | what it is |
|---|---|
| `ticker/` | a shell loop that writes its session name, generation and a counter, and carries the counter to a successor |
| `cron-note/` | a shell loop that appends a numbered UTC line every 2 minutes, with a marvel cadence on the same schedule |
| `relay/` | two shell seats that exchange a message on the bus with the `nats` command line tool |

The files here name no real person, host or path.

## Lab author identity

Git history built from these directories into the lab kit uses one fake author, so no
real identity is in the kit:

    Lab Author <lab-author@example.invalid>

This pull request itself is made under its author's own signed commits. The kit's
bundle history is made later, at kit build time.
