# Workloads

Three small workloads the lab ladder runs, and one optional fourth. Each directory holds a marvel manifest and
a README with the exact lines a passing run prints and how those lines were recorded.

| directory | what it is |
|---|---|
| `ticker/` | a shell loop that writes its session name, generation and a counter, and carries the counter to a successor |
| `cron-note/` | a shell loop that appends a numbered UTC line every 2 minutes, with a marvel cadence on the same schedule |
| `relay/` | two shell seats that exchange a message on the bus with the `nats` command line tool |
| `relay-claude/` | optional rung 10: two Claude seats that exchange one director message; spends model quota |

Each workload is its own marvel team (`ticker`, `cron-note`, `relay`) in the workspace `lab`,
because applying a manifest replaces the roles of the team it names: sharing one team would
retire the other workloads' seats. A session is named `<team>-<role>-g<generation>-<n>`.

The files here name no real person, host or path.

Each workload keeps its files under `${LAB_STATE:-$HOME/lab-run}/<workload>/`, a lab-owned
directory, so teardown has one place to look and nothing is written into marvel's own state.

## Lab author identity

Git history built from these directories into the lab kit uses one fake author, so no
real identity is in the kit:

    Lab Author <lab-author@example.invalid>

This pull request itself is made under its author's own signed commits. The kit's
bundle history is made later, at kit build time.
