# The check harness

`lab/run` runs the lab's checks and prints one verdict line per rung.

```sh
lab/run check 01     # one check
lab/run check all    # every check in order, stops at the first FAIL
lab/run digests      # digest lines for lab.lock
```

## A check

A check is `lab/check/<id>-<name>.sh`, run with bash from the lab root. It
prints exactly one line that starts with `RUNG ` and exits to match:

| line | exit |
|---|---|
| `RUNG <id> PASS` | 0 |
| `RUNG <id> SKIP <reason>` | 0 |
| `RUNG <id> FAIL <check-id>: <what was seen>` | 1 |

A SKIP is never counted as a pass. Other lines the check prints are passed
through, but a check must print no other line shaped like a verdict, that is
none that starts with `RUNG `: the harness reads a second one as a second
verdict and fails the rung with `H-noverdict`. Ids sort by their number, then their letter, so `0a` to `0g` run
before `01`, and `02` runs before `10`.

## What the harness refuses

A rung that the harness cannot trust prints `RUNG <id> FAIL H-<reason>: ...` and
the check is not trusted:

- `H-digest`: the script's sha256 differs from its line in `lab.lock`; it is not run.
- `H-nodigest`: no `digest` line for the script.
- `H-missing`, `H-ambiguous`: no script, or more than one, for the id.
- `H-nolock`: no `lab.lock`.
- `H-noverdict`: the script printed no `RUNG` line, or more than one.
- `H-shape`: the `RUNG` line is not one of the three shapes above.
- `H-mismatch`: the verdict and the exit status disagree.

## Version drift

`lab.lock` can list `version <name> <expected> <command words...>`. If the
command's first output line lacks `<expected>`, or the tool is missing, the
harness prints `WARN version <name>: ...` and carries on. Drift never fails a run.
A command that does not answer within `LAB_VERSION_TIMEOUT` seconds (default 5)
is stopped by its pid and WARNs `no answer in <n>s`; it never hangs or fails the run.

## Tests

```sh
env -i HOME="$(mktemp -d)" PATH="$PATH" bash lab/test/harness-test.sh
```

The tests build their own fixtures in a scratch directory and read nothing
from the real `lab.lock` or `lab/check`.
