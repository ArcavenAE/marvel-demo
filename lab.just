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

# Print the report for rung N; with an issue number, post it there too
[no-exit-message]
report $n $nonce $issue="" $denials="":
    #!/usr/bin/env bash
    set -euo pipefail
    [[ $n =~ ^[0-9]+[a-z]?$ ]] || { echo "lab: bad rung id" >&2; exit 1; }
    args=(--nonce "$nonce")
    [[ -z $denials ]] || args+=(--denials "$denials")
    [[ -z $issue ]] || args+=(--post --issue "$issue")
    exec lab/run exec lab/report "$n" "${args[@]}"
