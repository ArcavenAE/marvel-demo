#!/bin/bash
# Rung 12: teardown, walk it all back
# Run by lab/run, from the lab root, after it has checked this file's digest.
# Prints one RUNG line and exits 0 (PASS) or 1 (FAIL). It never acts: every call
# is a read (lsof, marvel get and config list, ssh-keygen -l, git remote, and
# the listing files you saved). It calls no gh and dials nothing past this
# machine. No here-document and no here-string: bash 3.2 writes those to /tmp,
# which a locked-down run denies.
#
#   C-td-1  no process listens on a lab port (LAB_PORTS, default 4222, the bus)
#   C-td-2  no key recorded in lab/state/lab-keys is in ~/.marvel/authorized_keys
#   C-td-4  no session is left in the lab workspace (a stopped daemon counts)
#   C-td-5  marvel config lists no cluster but local
#   C-td-3  your saved listings show no collaborator but the owner and no invitation
#           (runs last, so a report posted before the collaborator is removed reads C-td-3)

set -uo pipefail

ID=12
WAIT=${LAB_WAIT:-10}

pass() { printf 'RUNG %s PASS\n' "$ID"; exit 0; }
# fail <check-id> <what was seen>: the seen text is cut to one short line
fail() {
  local cid=$1 seen
  shift
  seen=$(printf '%s' "$*" | tr '\n' ' ' | cut -c1-200)
  printf 'RUNG %s FAIL %s: %s\n' "$ID" "$cid" "$seen"
  exit 1
}

# bounded <secs> <command words...>: run a command with no stdin, stop it by
# its pid when it does not finish in time. Sets B_OUT (its output) and B_RC
# (its exit status, 127 if it is not found, 124 if it timed out).
bounded() {
  local secs=$1 pids="" wpid cpid line t0 left
  shift
  B_OUT=""
  B_RC=0
  exec 7< <(sh -c '"$@" 2>&1 </dev/null & c=$!; echo "$$ $c"; wait $c; echo "__RC=$?"' sh "$@")
  t0=$SECONDS
  read -r -t "$secs" pids <&7 || true
  wpid=${pids%% *}
  cpid=${pids##* }
  while :; do
    left=$((secs - (SECONDS - t0)))
    if [[ $left -le 0 ]]; then B_RC=124; break; fi
    if read -r -t "$left" line <&7; then
      case $line in
        __RC=*) B_RC=${line#__RC=}; break ;;
      esac
      B_OUT="$B_OUT$line"$'\n'
    else
      B_RC=124
      break
    fi
  done
  if [[ $B_RC -eq 124 ]]; then
    for p in $cpid $wpid; do
      case $p in ''|*[!0-9]*) continue ;; esac
      kill -TERM "$p" 2>/dev/null || true
    done
    sleep 0.2
    for p in $cpid $wpid; do
      case $p in ''|*[!0-9]*) continue ;; esac
      if kill -0 "$p" 2>/dev/null; then kill -KILL "$p" 2>/dev/null || true; fi
    done
  fi
  exec 7<&-
}


command -v marvel >/dev/null 2>&1 || fail C-td "marvel is not on PATH"
command -v python3 >/dev/null 2>&1 || fail C-td "python3 is not on PATH"

# C-td-1: nothing listens on a lab port.
command -v lsof >/dev/null 2>&1 || fail C-td-1 "lsof is not on PATH, so the lab ports cannot be read"
for port in ${LAB_PORTS:-4222}; do
  [[ $port =~ ^[1-9][0-9]*$ ]] || fail C-td-1 "the lab port [$port] is not a number"
  bounded "$WAIT" lsof -nP "-iTCP:$port" -sTCP:LISTEN -t
  [[ $B_RC -ne 124 ]] || fail C-td-1 "lsof did not answer in ${WAIT}s for port $port"
  [[ $B_RC -le 1 ]] || fail C-td-1 "lsof failed for port $port (exit $B_RC)"
  pids=$(printf '%s' "$B_OUT" | tr '\n' ' ')
  [[ -z ${pids// /} ]] || fail C-td-1 "port $port still has a listener (pid $pids): stop the lab teams and the bus"
done

# C-td-2: the lab keys are gone from this host's authorized_keys. The list of
# lab keys is lab/state/lab-keys, one SHA256 fingerprint per line.
command -v ssh-keygen >/dev/null 2>&1 || fail C-td-2 "ssh-keygen is not on PATH"
KEYS=lab/state/lab-keys
[[ -s $KEYS ]] || fail C-td-2 "$KEYS is missing or empty: it holds the fingerprint of each key you authorized for the lab, one per line"
labfps=""
while read -r fp rest; do
  [[ -n $fp ]] || continue
  [[ $fp =~ ^SHA256:[A-Za-z0-9+/]+$ ]] || fail C-td-2 "$KEYS has a line that is not a SHA256 fingerprint: $fp"
  labfps="$labfps $fp"
done <"$KEYS"
[[ -n $labfps ]] || fail C-td-2 "$KEYS holds no fingerprint"
AK=${HOME:-/nonexistent}/.marvel/authorized_keys
if [[ -s $AK ]]; then
  bounded "$WAIT" ssh-keygen -lf "$AK"
  [[ $B_RC -eq 0 ]] || fail C-td-2 "ssh-keygen could not read $AK as keys (exit $B_RC)"
  for fp in $labfps; do
    case " $(printf '%s' "$B_OUT" | awk '{print $2}' | tr '\n' ' ')" in
      *" $fp "*) fail C-td-2 "the lab key $fp is still in $AK: run marvel keys revoke $fp" ;;
    esac
  done
fi

# C-td-4: no seat is left in the lab workspace. A stopped daemon has none.
bounded "$WAIT" marvel get sessions -o json
if [[ $B_RC -ne 0 ]]; then
  case $B_OUT in
    *"connect to daemon"*) ;;
    *) fail C-td-4 "marvel get sessions failed (exit $B_RC)" ;;
  esac
else
  left=$(printf '%s\n' "$B_OUT" | sed -n '/^\[/,$p' | python3 -I -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
print(" ".join(s.get("Name", "") for s in d if s.get("Workspace") == "lab"))' 2>/dev/null) || fail C-td-4 "could not read the marvel get sessions answer"
  [[ -z $left ]] || fail C-td-4 "seats are still running in the lab workspace: $left"
fi

# C-td-5: no cluster but local.
bounded "$WAIT" marvel config list
[[ $B_RC -eq 0 ]] || fail C-td-5 "marvel config list failed (exit $B_RC)"
rows=$(printf '%s\n' "$B_OUT" | awk 'NR > 1 { n = ($1 == "*") ? $2 : $1; if (n != "") print n }')
[[ -n $rows ]] || fail C-td-5 "marvel config list printed no cluster, not even local"
other=$(printf '%s\n' "$rows" | grep -v -x local | tr '\n' ' ' || true)
[[ -z ${other// /} ]] || fail C-td-5 "clusters beyond local are still configured: $other: run marvel config remove-cluster"
# C-td-3 runs last: the report is posted before the collaborator is removed, so the
# posted line reads C-td-3 and shows that C-td-1, 2, 4 and 5 already passed.
# C-td-3: the repository has no collaborator but its owner, and no pending
# invitation. The check calls no gh and dials nothing: it reads two listings you
# saved with gh after the teardown started (lab/state/teardown-start is the
# marker), and the owner's login from this tree's origin.
MARK=lab/state/teardown-start
COLLAB=lab/state/collaborators
INVITE=lab/state/invitations
command -v git >/dev/null 2>&1 || fail C-td-3 "git is not on PATH"
url=$(git remote get-url origin 2>/dev/null || true)
u=${url%/}
u=${u%.git}
name='[A-Za-z0-9][A-Za-z0-9._-]*'
owner=""
for form in "^https://github\\.com/($name)/($name)\$" "^git@github\\.com:($name)/($name)\$" "^ssh://git@github\\.com/($name)/($name)\$"; do
  if [[ $u =~ $form ]]; then
    owner=${BASH_REMATCH[1]}
    break
  fi
done
[[ -n $owner ]] || fail C-td-3 "this tree has no github.com origin, so the owner's login is unknown"
[[ -f $MARK ]] || fail C-td-3 "$MARK is missing: create it when you start the teardown, before you post the report"
[[ -f $COLLAB ]] || fail C-td-3 "$COLLAB is missing: after removing the collaborator, save the listing (see the rung text)"
[[ -f $INVITE ]] || fail C-td-3 "$INVITE is missing: after removing the collaborator, save the invitation listing (see the rung text)"
[[ $COLLAB -nt $MARK ]] || fail C-td-3 "$COLLAB is older than $MARK: save the listing again after you remove the collaborator"
[[ $INVITE -nt $MARK ]] || fail C-td-3 "$INVITE is older than $MARK: save the listing again after you remove the invitation"
set -f
logins=$(cat "$COLLAB")
[[ -n ${logins//[[:space:]]/} ]] || fail C-td-3 "$COLLAB is empty: it should list at least the owner"
lc_owner=$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')
extra=""
for login in $logins; do
  lc_login=$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')
  [[ $lc_login == "$lc_owner" ]] || extra="$extra $login"
done
[[ -z $extra ]] || fail C-td-3 "still listed as a collaborator:$extra: remove them, then save the listing again"
pending=$(cat "$INVITE" | tr '\n' ' ')
set +f
[[ -z ${pending//[[:space:]]/} ]] || fail C-td-3 "an invitation is still pending for: $pending"

pass
