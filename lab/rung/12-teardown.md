# Rung 12: teardown

Demo: you walk the lab back. The daemon, keys and clusters go first, then the report is posted, then the invited collaborator is removed, and the check confirms each piece.

You, in this order:

1. Stop the daemon yourself with `marvel stop --teardown`. It ends every seat and the managed bus.
2. List, one per line in `lab/state/lab-keys`, the fingerprint of every key you authorized for the lab. `ssh-keygen -lf <public key file>` prints one. Then run `marvel keys revoke <fingerprint>` for each, on the host that authorized it. Run `just lab check 12` on each lab host, because the check reads that host's `~/.marvel/authorized_keys`.
3. Remove each cluster you added for the lab with `marvel config remove-cluster <name>`.
4. Mark the start with `touch lab/state/teardown-start`. Then post the report while the invited collaborator can still read it (on a private repository they cannot once they are removed): `just lab report 12 <nonce> <issue>` (the nonce is a string you choose, 8 to 64 letters, digits, `-` or `_`, and the issue is the number to post on). The check inside the report runs the collaborator step last, so the posted report is expected to read `RUNG 12 FAIL C-td-3`. That shows every other step already passed, and the collaborator is the one piece still pending. The post is for the record.
5. Remove the invited collaborator, and any invitation not yet accepted, from the repository's settings on GitHub. Then save two listings yourself, under your own login, from the lab root, with OWNER/REPO being this tree's origin: `gh api repos/OWNER/REPO/collaborators --paginate --jq '.[].login' > lab/state/collaborators` and `gh api repos/OWNER/REPO/invitations --paginate --jq '.[].invitee.login' > lab/state/invitations`. Both only read. The check calls no gh itself.
6. Run `just lab check 12` again for the final PASS. It passes when `lsof` finds no listener on the bus port (4222), none of the keys in `lab/state/lab-keys` is in `~/.marvel/authorized_keys`, no seat is left in the lab workspace, `marvel config list` shows only `local`, and your saved listings are newer than `lab/state/teardown-start`, name no collaborator but the repository's owner and show no pending invitation.

## Tools

- marvel, with `marvel stop --teardown`, `marvel keys revoke` and `marvel config remove-cluster`. None of the three is on the agent's allow list, so it may ask you first; you run them yourself.
- `lsof`, `ssh-keygen` and `git`, which the check reads with. The check dials nothing. You run `gh` (signed in) yourself for the two listings in step 5.
- `lab/state/lab-keys`: one `SHA256:` fingerprint per line, written by you. `ssh-keygen -lf <public key file>` prints a fingerprint.

## Expected prompts

- You run every command here yourself, so the agent's permission prompts do not apply. Where a command asks you to confirm, answer yes.
- If you ask the agent to run `just lab check 12` or `just lab report 12`, they are reads and a post to one issue; the stop, revoke and remove-cluster commands are not on its allow list, so it may ask you first.

## Left in place

Teardown removes what the ladder installed on the lab's side. It leaves these, and you decide whether to undo each:

- `~/.marvel`: your keys, host key, known_hosts and config.
- `~/lab-run`: the workload files and logs.
- the bd database, and the issues in it.
- the brew packages the install rungs added.
- Remote Login, if you turned it on for a second machine.
- the Local Network permission you granted.
- `pmset -c sleep 0`, which stays until you set it back.
