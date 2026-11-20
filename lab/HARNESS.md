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

## The class rule

Every file a `just lab` recipe executes is pinned in `lab.lock` and run through
`lab/run`'s digest check. A recipe may print an unpinned file, as `rung` does
with the rung instructions, but never executes one. `lab/run exec <path>` is
the way a recipe runs a file: the path must be `lab/` and plain names (no `.`,
no `..`, no symlink), it needs a `digest` line in `lab.lock` and must match it,
and then it runs with bash from the lab root. `lab/report` and
`lab/verify-report` are pinned and run this way; `lab/report` itself runs
nothing else under `lab/` and reads the denials file only as text.

## Reports

`just lab report N NONCE` prints the report for rung N in a fixed shape; with
an issue number it also posts the same bytes as a comment on that issue. The
repo comes only from this tree's own `origin` (github.com), and there is no
flag to name another. Before a post, `lab/verify-report` must accept the body.
The verdict, version lines and denials block are cleaned first: control
characters dropped, and your home directory, user name and host name replaced
by `~`, `<user>` and `<host>`. The host name covers `hostname`, `hostname -s`, and where
`scutil` answers, the LocalHostName with and without `.local`, and the ComputerName. `lab/verify-report FILE|- [--nonces FILE]` checks
a report's shape (exit 0 valid, 1 invalid, 3 valid with a stale or unknown
nonce, 2 usage); the nonce list holds issued nonces, oldest first, and only the
last is fresh. `lab/run versions` prints what each pinned tool says now.

## The roots of trust

The digest check cannot cover the files that do the checking or choose what
runs, so each is a root of trust and the agent may not edit it. Each has an
`Edit` deny in `.claude/settings.json` that `lab/check-settings` requires:

- `lab/run`: the harness that checks every digest.
- `lab.lock`: the digests and pins the harness compares against.
- `lab.just`: the recipes, which choose what a `just lab` command runs.
- `justfile`: the root file that loads the recipes.
- `.claude/settings.json`: the permissions themselves.
- `lab/check-settings`: the check that those permissions are the right ones.

The same files stay out of reach of an allowed command: the `just lab` recipes
only print a rung file, run a pinned file through `lab/run`, or run `lab/run`,
and none redirects into a root. A report's denials file is read only from
`lab/state/`, never from another path.
