# bd-ticker

A shell seat that files one bd issue, so rung 8 has something for you to show and close.

On its first tick the seat asks bd for issues labelled `lab-ticker-note`. If one already carries this
session's title it files nothing; otherwise it files one issue:

    title:  lab note from ticker seat <session>
    labels: lab, lab-ticker-note

It then appends `<session> tick <n>` every 5 seconds to
`${LAB_STATE:-$HOME/lab-run}/bd-ticker/<session>.log`. It never closes or edits an issue; closing is your step.
Without `bd` on `PATH` it logs `<session> bd not found` and keeps ticking. It must run in a directory inside the lab's bd workspace.

## Expected lines

    bd-ticker-ticker-g1-0 filed <issue id>
    bd-ticker-ticker-g1-0 tick 1
    bd-ticker-ticker-g1-0 tick 2

## Tests

`python3 -I -B -m unittest discover -s workloads/bd-ticker -p 'test_*.py'` (Python 3.11 or newer) runs the script
under a stub `bd`. The real bd is not run.
