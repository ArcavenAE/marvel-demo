# Print the instructions for rung N
[no-exit-message]
rung $n:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ $n =~ ^[0-9]+[a-z]?$ ]] || { echo "lab: bad rung id" >&2; exit 1; }
    for f in lab/rung/"$n"-*.md; do
      if [[ -e $f ]]; then cat "$f"; exit 0; fi
    done
    echo "lab: no instructions for rung $n yet" >&2
    exit 1

# Run the check for rung N, or all of them
[no-exit-message]
check $n:
    @lab/run check "$n"

# Post the report for rung N
[no-exit-message]
report $n:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ $n =~ ^[0-9]+[a-z]?$ ]] || { echo "lab: bad rung id" >&2; exit 1; }
    if [[ ! -x lab/report ]]; then
      echo "lab: lab/report does not exist yet" >&2
      exit 1
    fi
    exec lab/report "$n"
