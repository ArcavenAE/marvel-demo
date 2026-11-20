"""Tests for lab/check-settings and the lab's .claude/settings.json.

Run with:  env -i HOME=<scratch> TMPDIR=<scratch> PATH=$PATH python3 -I lab/test/test_check_settings.py

Every check runs against a scratch copy of the kit settings and a scratch
HOME that this file creates itself. Nothing here reads or writes the caller's
HOME, and nothing here uses the network.

The check ids are the acceptance checks of the kit plan:
  C-set-1  no key of the auto-mode family in any kit file
  C-set-2  no allow rule on the forbidden list
  C-set-3  every required deny is present
  C-set-4  no path outside the project directory
  C-set-5  the user settings hash is unchanged across install
"""
import copy
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CHECK = os.path.join(REPO, "lab", "check-settings")
SETTINGS = os.path.join(REPO, ".claude", "settings.json")

# Built from parts so this file never contains the word it forbids elsewhere.
NEEDLE = "auto" + "Mode"

REQUIRED_DENY = [
    "Read(~/.ssh/**)",
    "Read(~/.marvel/keys/**)",
    "Read(~/.marvel/ssh_host_ed25519_key)",
    "Read(~/.claude/.credentials*)",
    "Read(~/.config/gh/**)",
    "Bash(security find-generic-password:*)",
    "Bash(gh auth token:*)",
    "Bash(marvel keys authorize:*)",
    "Bash(marvel config add-cluster:*)",
    "Bash(./lab/deny-probe:*)",
    # Director's call: the agent may not edit the files the gates trust.
    "Edit(./lab/check-settings)",
    "Edit(./lab/test/**)",
    "Edit(./lab/run)",
    "Edit(./lab.lock)",
    "Edit(./lab/HARNESS.md)",
]

EXPECTED_ALLOW = [
    "Bash(marvel get:*)",
    "Bash(marvel doctor:*)",
    "Bash(marvel capture:*)",
    "Bash(marvel events:*)",
    "Bash(bd show:*)",
    "Bash(bd ready:*)",
    "Bash(just lab rung:*)",
    "Bash(just lab check:*)",
    "Bash(just lab report:*)",
    "Read(./lab/**)",
    "Edit(./lab/**)",
]

results = []
scratch_root = tempfile.mkdtemp(prefix="lab-set-", dir=os.environ.get("TMPDIR") or None)


def record(name, ok, msg=""):
    results.append((name, bool(ok), msg))
    print("  %s  %s%s" % ("ok  " if ok else "FAIL", name, "" if ok else "  -- " + msg))


def load_settings():
    try:
        with open(SETTINGS, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def new_dir(label):
    return tempfile.mkdtemp(prefix=label + "-", dir=scratch_root)


def make_project(mutate=None, raw=None, extra_files=None):
    """A scratch project holding a mutated copy of the kit settings."""
    proj = new_dir("proj")
    os.makedirs(os.path.join(proj, ".claude"))
    os.makedirs(os.path.join(proj, "lab"))
    base = load_settings()
    if raw is not None:
        text = raw
    else:
        doc = copy.deepcopy(base) if base is not None else {}
        if mutate:
            mutate(doc)
        text = json.dumps(doc, indent=2) + "\n"
    with open(os.path.join(proj, ".claude", "settings.json"), "w", encoding="utf-8") as fh:
        fh.write(text)
    for rel, body in (extra_files or {}).items():
        path = os.path.join(proj, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
    return proj


def run_check(args, home):
    env = {"HOME": home, "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LANG": "C"}
    try:
        p = subprocess.run([sys.executable, "-I", CHECK] + args, env=env, cwd=scratch_root,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, "could not run check-settings: %s" % exc
    return p.returncode, p.stdout.decode("utf-8", "replace")


def check_project(proj):
    home = new_dir("home")
    return run_check(["--project", proj], home)


def line_status(out, cid):
    for line in (out or "").splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == cid:
            return parts[1]
    return None


def expect_fail(name, cid, mutate=None, raw=None, extra_files=None):
    """The mutated project must make check cid FAIL and the command exit 1,
    while a different check that the mutation does not touch still reports."""
    proj = make_project(mutate=mutate, raw=raw, extra_files=extra_files)
    rc, out = check_project(proj)
    st = line_status(out, cid)
    record(name, rc == 1 and st == "FAIL",
           "want rc 1 and %s FAIL, got rc %r and %s %r; output: %s" % (cid, rc, cid, st, (out or "")[:300]))


def expect_fail_all(name, cids, mutate=None, raw=None, extra_files=None, setup=None):
    """Every check in cids must report FAIL and the command must exit 1."""
    proj = make_project(mutate=mutate, raw=raw, extra_files=extra_files)
    if setup:
        setup(proj)
    rc, out = check_project(proj)
    sts = dict((c, line_status(out, c)) for c in cids)
    record(name, rc == 1 and all(v == "FAIL" for v in sts.values()),
           "want rc 1 and FAIL for %s, got rc %r and %r; output: %s" % (cids, rc, sts, (out or "")[:300]))


def expect_pass(name, cid, mutate=None):
    proj = make_project(mutate=mutate)
    rc, out = check_project(proj)
    record(name, line_status(out, cid) == "PASS",
           "want %s PASS, got %r: %s" % (cid, line_status(out, cid), (out or "")[:300]))


def allow(doc):
    return doc.setdefault("permissions", {}).setdefault("allow", [])


def deny(doc):
    return doc.setdefault("permissions", {}).setdefault("deny", [])


def tree_digest(root):
    h = hashlib.sha256()
    for dp, dn, fn in sorted(os.walk(root)):
        dn.sort()
        for f in sorted(fn):
            p = os.path.join(dp, f)
            h.update(os.path.relpath(p, root).encode())
            with open(p, "rb") as fh:
                h.update(fh.read())
    return h.hexdigest()


# ---------------------------------------------------------------- baseline

def test_baseline():
    base = load_settings()
    record("baseline: .claude/settings.json exists and parses", base is not None,
           "missing or not JSON: %s" % SETTINGS)
    proj = make_project()
    rc, out = check_project(proj)
    sts = [line_status(out, "C-set-%d" % n) for n in (1, 2, 3, 4)]
    record("baseline: the kit settings pass C-set-1 to C-set-4 and exit 0",
           rc == 0 and sts == ["PASS"] * 4, "rc %r, statuses %r, output: %s" % (rc, sts, (out or "")[:300]))
    if base is not None:
        perm = base.get("permissions", {})
        record("baseline: the allow set is the F1 set, no more and no less",
               sorted(perm.get("allow", [])) == sorted(EXPECTED_ALLOW),
               "allow is %r" % perm.get("allow"))
        record("baseline: the deny set contains every required deny",
               all(d in perm.get("deny", []) for d in REQUIRED_DENY),
               "missing %r" % [d for d in REQUIRED_DENY if d not in perm.get("deny", [])])
        record("baseline: the file has only a permissions block",
               sorted(base.keys()) == ["permissions"], "keys are %r" % sorted(base.keys()))
    else:
        for n in ("the allow set is the F1 set, no more and no less",
                  "the deny set contains every required deny",
                  "the file has only a permissions block"):
            record("baseline: " + n, False, "no settings file to read")


def test_cset1():
    # Real kit tree: the word appears nowhere (grep -c over every kit file is 0).
    total = 0
    files = 0
    for dp, dn, fn in os.walk(REPO):
        dn[:] = [d for d in dn if d != ".git"]
        for f in fn:
            try:
                with open(os.path.join(dp, f), "rb") as fh:
                    total += fh.read().count(NEEDLE.encode())
                files += 1
            except OSError:
                pass
    record("C-set-1: the real kit tree has zero matches, and has the settings file",
           total == 0 and os.path.exists(SETTINGS), "count %d, settings present %s" % (total, os.path.exists(SETTINGS)))
    expect_fail("C-set-1: the key in the settings file fails", "C-set-1",
                mutate=lambda d: d.update({NEEDLE: {"allow": ["x"]}}))
    expect_fail("C-set-1: the word in a nested key fails", "C-set-1",
                mutate=lambda d: d.setdefault("permissions", {}).update({NEEDLE: True}))
    expect_fail("C-set-1: the word in another kit file fails", "C-set-1",
                extra_files={"lab/notes.md": "x\n%s: y\n" % NEEDLE})
    expect_fail("C-set-1: the word in a hidden kit file fails", "C-set-1",
                extra_files={".claude/settings.local.json": "{\"%s\": 1}\n" % NEEDLE})


def test_cset2():
    cases = [
        ("a bare Bash allow", lambda d: allow(d).append("Bash")),
        ("Bash(*)", lambda d: allow(d).append("Bash(*)")),
        ("Bash(marvel:*)", lambda d: allow(d).append("Bash(marvel:*)")),
        ("Bash(marvel *)", lambda d: allow(d).append("Bash(marvel *)")),
        ("Bash(gh:*)", lambda d: allow(d).append("Bash(gh:*)")),
        ("Bash(tmux:*)", lambda d: allow(d).append("Bash(tmux:*)")),
        ("Bash(bash:*)", lambda d: allow(d).append("Bash(bash:*)")),
        ("Bash(python3:*)", lambda d: allow(d).append("Bash(python3:*)")),
        ("a wildcard inside a command", lambda d: allow(d).append("Bash(marvel g*)")),
        ("a bare Read allow", lambda d: allow(d).append("Read")),
        ("a bare Edit allow", lambda d: allow(d).append("Edit")),
        ("a bare Write allow", lambda d: allow(d).append("Write")),
        ("an MCP tool allow", lambda d: allow(d).append("mcp__x__y")),
        ("an allow equal to a required deny",
         lambda d: allow(d).append("Bash(gh auth token:*)")),
        ("defaultMode bypassPermissions",
         lambda d: d.setdefault("permissions", {}).update({"defaultMode": "bypassPermissions"})),
        ("defaultMode dontAsk",
         lambda d: d.setdefault("permissions", {}).update({"defaultMode": "dontAsk"})),
        ("an env block", lambda d: d.update({"env": {"A": "b"}})),
        ("an empty env block", lambda d: d.update({"env": {}})),
        ("an mcpServers block", lambda d: d.update({"mcpServers": {"s": {"command": "x"}}})),
        ("enableAllProjectMcpServers", lambda d: d.update({"enableAllProjectMcpServers": True})),
        ("enabledMcpjsonServers", lambda d: d.update({"enabledMcpjsonServers": ["s"]})),
    ]
    for label, fn in cases:
        expect_fail("C-set-2: %s fails" % label, "C-set-2", mutate=fn)
    # The F1 allows alone must not trip the check (control for the cases above).
    proj = make_project()
    rc, out = check_project(proj)
    record("C-set-2: the unmutated F1 allows pass", line_status(out, "C-set-2") == "PASS",
           "got %r: %s" % (line_status(out, "C-set-2"), (out or "")[:200]))


def test_cset3():
    for d in REQUIRED_DENY:
        expect_fail("C-set-3: removing %s fails" % d, "C-set-3",
                    mutate=lambda doc, d=d: doc.setdefault("permissions", {}).update(
                        {"deny": [x for x in doc.get("permissions", {}).get("deny", []) if x != d]}))
    expect_fail("C-set-3: an empty deny list fails", "C-set-3",
                mutate=lambda doc: doc.setdefault("permissions", {}).update({"deny": []}))
    expect_fail("C-set-3: no deny key fails", "C-set-3",
                mutate=lambda doc: doc.setdefault("permissions", {}).pop("deny", None))


def test_cset4():
    cases = [
        ("Read of an absolute path", lambda d: allow(d).append("Read(//etc/**)")),
        ("Read of a home path", lambda d: allow(d).append("Read(~/notes/**)")),
        ("Edit of a parent path", lambda d: allow(d).append("Edit(../other/**)")),
        ("Edit with a dot-dot inside", lambda d: allow(d).append("Edit(./lab/../../x)")),
        ("Read rooted at a slash", lambda d: allow(d).append("Read(/lab/**)")),
        ("Write of an absolute path", lambda d: allow(d).append("Write(//tmp/x)")),
        ("a Bash allow naming an absolute path", lambda d: allow(d).append("Bash(cat /etc/hosts:*)")),
        ("a Bash allow naming a home path", lambda d: allow(d).append("Bash(cat ~/x:*)")),
        ("a Bash allow naming a parent path", lambda d: allow(d).append("Bash(cat ../x:*)")),
        ("a hook command outside the tree",
         lambda d: d.update({"hooks": {"PreToolUse": [{"hooks": [{"type": "command",
                                                                     "command": "/opt/x/run"}]}]}})),
        ("a hook command with a parent path",
         lambda d: d.update({"hooks": {"PreToolUse": [{"hooks": [{"type": "command",
                                                                     "command": "../x/run"}]}]}})),
    ]
    for label, fn in cases:
        expect_fail("C-set-4: %s fails" % label, "C-set-4", mutate=fn)
    proj = make_project(mutate=lambda d: d.update(
        {"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "./lab/hook-ok"}]}]}}))
    rc, out = check_project(proj)
    record("C-set-4: a hook command inside the tree passes C-set-4",
           line_status(out, "C-set-4") == "PASS", "got %r: %s" % (line_status(out, "C-set-4"), (out or "")[:200]))
    proj = make_project()
    rc, out = check_project(proj)
    record("C-set-4: the unmutated settings pass", line_status(out, "C-set-4") == "PASS",
           "got %r: %s" % (line_status(out, "C-set-4"), (out or "")[:200]))


def test_input_errors():
    proj = make_project(raw="{not json")
    rc, out = check_project(proj)
    record("input: a settings file that is not JSON exits 1 and says so",
           rc == 1 and "not valid json" in (out or "").lower(), "rc %r: %s" % (rc, (out or "")[:200]))
    proj = make_project(raw="null\n")
    rc, out = check_project(proj)
    record("input: a settings file holding JSON null exits 1 and says so",
           rc == 1 and "not a json object" in (out or "").lower() and "Traceback" not in (out or ""),
           "rc %r: %s" % (rc, (out or "")[:200]))
    proj = new_dir("proj")
    rc, out = check_project(proj)
    record("input: a project with no settings file exits 1 and says so",
           rc == 1 and "settings" in (out or "").lower(), "rc %r: %s" % (rc, (out or "")[:200]))
    rc, out = run_check(["--no-such-flag"], new_dir("home"))
    record("input: an unknown flag exits 2 and prints a usage line",
           rc == 2 and "usage:" in (out or "").lower() and "can't open" not in (out or ""),
           "rc %r: %s" % (rc, (out or "")[:200]))


def write_user_settings(home, text):
    os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
    with open(os.path.join(home, ".claude", "settings.json"), "w", encoding="utf-8") as fh:
        fh.write(text)


def fake_install(proj_target):
    """Stand-in for the kit install: put the lab settings in a project dir."""
    os.makedirs(os.path.join(proj_target, ".claude"), exist_ok=True)
    if os.path.exists(SETTINGS):
        shutil.copyfile(SETTINGS, os.path.join(proj_target, ".claude", "settings.json"))


def test_cset5():
    home = new_dir("home")
    write_user_settings(home, '{"theme": "dark"}\n')
    snap = os.path.join(scratch_root, "snap-a")
    rc1, out1 = run_check(["--user-snapshot", snap], home)
    fake_install(new_dir("target"))
    rc2, out2 = run_check(["--user-verify", snap], home)
    record("C-set-5: an install that leaves user settings alone passes",
           rc1 == 0 and rc2 == 0 and line_status(out2, "C-set-5") == "PASS",
           "snapshot rc %r, verify rc %r: %s" % (rc1, rc2, (out2 or "")[:200]))

    home = new_dir("home")
    write_user_settings(home, '{"theme": "dark"}\n')
    snap = os.path.join(scratch_root, "snap-b")
    run_check(["--user-snapshot", snap], home)
    write_user_settings(home, '{"theme": "dark", "x": 1}\n')
    rc, out = run_check(["--user-verify", snap], home)
    record("C-set-5: a changed user settings file fails",
           rc == 1 and line_status(out, "C-set-5") == "FAIL", "rc %r: %s" % (rc, (out or "")[:200]))

    home = new_dir("home")
    snap = os.path.join(scratch_root, "snap-c")
    rc1, _ = run_check(["--user-snapshot", snap], home)
    rc2, out2 = run_check(["--user-verify", snap], home)
    record("C-set-5: no user settings before and after passes",
           rc1 == 0 and rc2 == 0 and line_status(out2, "C-set-5") == "PASS",
           "rc %r %r: %s" % (rc1, rc2, (out2 or "")[:200]))

    home = new_dir("home")
    snap = os.path.join(scratch_root, "snap-d")
    run_check(["--user-snapshot", snap], home)
    write_user_settings(home, "{}\n")
    rc, out = run_check(["--user-verify", snap], home)
    record("C-set-5: a user settings file created by the install fails",
           rc == 1 and line_status(out, "C-set-5") == "FAIL", "rc %r: %s" % (rc, (out or "")[:200]))

    home = new_dir("home")
    write_user_settings(home, '{"theme": "dark"}\n')
    snap = os.path.join(scratch_root, "snap-e")
    run_check(["--user-snapshot", snap], home)
    os.remove(os.path.join(home, ".claude", "settings.json"))
    rc, out = run_check(["--user-verify", snap], home)
    record("C-set-5: a user settings file removed by the install fails",
           rc == 1 and line_status(out, "C-set-5") == "FAIL", "rc %r: %s" % (rc, (out or "")[:200]))

    rc, out = run_check(["--user-verify", os.path.join(scratch_root, "no-such-snapshot")], new_dir("home"))
    record("C-set-5: a missing snapshot file fails",
           rc == 1 and line_status(out, "C-set-5") == "FAIL", "rc %r: %s" % (rc, (out or "")[:200]))


def test_no_writes_to_home():
    home = new_dir("home")
    write_user_settings(home, '{"theme": "dark"}\n')
    before = tree_digest(home)
    proj = make_project()
    rc, out = run_check(["--project", proj], home)
    snap = os.path.join(scratch_root, "snap-w")
    run_check(["--user-snapshot", snap], home)
    run_check(["--user-verify", snap], home)
    after = tree_digest(home)
    record("home: check-settings reports its checks and never writes under HOME",
           before == after and line_status(out, "C-set-1") is not None,
           "digest changed or the run printed no C-set-1 line: %s" % (out or "")[:200])


def test_failopen_first_word():
    """An allow whose first word is a shell or interpreter grants arbitrary code."""
    for rule in ("Bash(bash -c:*)", "Bash(sh -c:*)", "Bash(zsh -c:*)", "Bash(python3 -c:*)",
                 "Bash(python -c:*)", "Bash(env A=1:*)", "Bash(sudo ls:*)", "Bash(curl -s x:*)",
                 "Bash(ssh host cmd:*)", "Bash(A=1 bash -c:*)", "Bash(./sh -c:*)",
                 "Bash(node -e:*)", "Bash(xargs rm:*)", "Bash(eval x:*)"):
        expect_fail("fail-open 1: %s fails C-set-2" % rule, "C-set-2",
                    mutate=lambda d, r=rule: allow(d).append(r))
    for rule in ("Bash(marvel:*)", "Bash(gh:*)", "Bash(tmux:*)", "Bash(marvel *)"):
        expect_fail("fail-open 1: one-word %s still fails" % rule, "C-set-2",
                    mutate=lambda d, r=rule: allow(d).append(r))
    # Controls: a narrow multi-word allow on a lab tool, and a word that only
    # starts like a shell, must not trip the first-word rule.
    expect_pass("fail-open 1: control, Bash(marvel get:*) passes C-set-2", "C-set-2",
                mutate=lambda d: allow(d).append("Bash(marvel get:*)"))
    # A word that only starts like a shell is not on the grant list either.
    expect_fail("fail-open 1: Bash(bashful lab:*) is not a granted line", "C-set-2",
                mutate=lambda d: allow(d).append("Bash(bashful lab:*)"))


GRANTED_LINES = [
    "Bash(marvel get:*)", "Bash(marvel doctor:*)", "Bash(marvel capture:*)",
    "Bash(marvel events:*)", "Bash(bd show:*)", "Bash(bd ready:*)",
    "Bash(just lab rung:*)", "Bash(just lab check:*)", "Bash(just lab report:*)",
]


def test_allowlist():
    """C-set-2 on a Bash allow is an allowlist: only the F1 grant lines pass,
    each with its required verb. Everything else FAILs, whatever it is."""
    classes = [
        ("wrapper", ["command bash", "nice bash", "timeout 5 bash", "nohup bash", "time bash",
                     "stdbuf -o0 bash", "doas bash", "su root", "watch bash", "script -c bash",
                     "command marvel get", "nice marvel get", "timeout 5 marvel get",
                     "nohup marvel get", "time marvel get", "stdbuf -o0 marvel get"]),
        ("off-list shell or interpreter", ["fish -c x", "dash -c x", "ksh -c x", "osascript -e x",
                                           "awk x", "php -r x", "lua -e x", "deno run x",
                                           "bun run x", "uv run x", "uvx x", "pwsh -c x",
                                           "tclsh x", "jq x", "sed x", "find x"]),
        ("exec path", ["find . -exec sh", "make x", "git x", "git config x", "xargs sh", "rsync x"]),
        ("spelling of a shell", ["Bash -c", "BASH -c", "'bash' -c", "\"bash\" -c", "\\bash -c",
                                 "b'a'sh -c", "ba\\sh -c", "/bin/bash -c", "./bash -c",
                                 "bash\t-c"]),
        ("case of a granted word", ["Marvel get", "MARVEL get", "marvel GET", "Bd show", "BD show",
                                    "Just lab rung", "just LAB rung", "just lab RUNG"]),
        ("granted word without its verb", ["marvel", "bd", "just", "just lab", "marvel getx",
                                           "marvel gets", "bd showx", "just lab rungs",
                                           "just labs rung", "just rung"]),
        ("other verb of a granted word", ["marvel inject", "marvel attach", "marvel keys authorize",
                                          "marvel config add-cluster", "marvel apply",
                                          "marvel daemon", "bd create", "bd close", "bd update",
                                          "bd sql", "just deploy", "just lab teardown",
                                          "just lab", "just --list", "just -f x lab rung"]),
        ("other tool", ["gh pr", "tmux send-keys", "security find-generic-password", "ls", "cat x",
                        "echo x", "cp x y", "mv x y", "ssh h", "curl x"]),
        ("leading assignment or path", ["A=1 marvel get", "PATH=. marvel get", "./marvel get",
                                        "/usr/bin/marvel get", "../marvel get", "~/marvel get"]),
        ("shell metacharacter in the prefix", ["marvel get; bash", "marvel get && x", "marvel get | sh",
                                               "marvel get $(x)", "marvel get `x`", "marvel get > x",
                                               "marvel get < x", "marvel get\nbash", "marvel get &",
                                               "bd show (x)", "bd show {x}", "bd show #x",
                                               "just lab rung !x", "just lab rung ~x"]),
    ]
    for label, specs in classes:
        for spec in specs:
            rule = "Bash(%s:*)" % spec
            expect_fail("allowlist: %s: %s fails C-set-2" % (label, spec.replace("\n", "\\n").replace("\t", "\\t")),
                        "C-set-2", mutate=lambda d, r=rule: allow(d).append(r))
    # The wildcard form with a space also has to meet the list.
    expect_fail("allowlist: Bash(bash -c *) with a space wildcard fails C-set-2", "C-set-2",
                mutate=lambda d: allow(d).append("Bash(bash -c *)"))
    expect_fail("allowlist: Bash(marvel get) with no wildcard but a bad verb fails C-set-2", "C-set-2",
                mutate=lambda d: allow(d).append("Bash(marvel inject)"))
    # Positive controls: each granted line passes alone, with extra arguments,
    # and in the space-wildcard spelling.
    for line in GRANTED_LINES:
        expect_pass("allowlist: control, %s passes C-set-2" % line, "C-set-2",
                    mutate=lambda d, r=line: allow(d).append(r))
    for spec in ("marvel get pods", "marvel doctor --json", "marvel capture desk1", "marvel events --since 5m",
                 "bd show x-1", "bd ready", "just lab rung 03", "just lab check 03", "just lab report 03"):
        expect_pass("allowlist: control, Bash(%s:*) passes C-set-2" % spec, "C-set-2",
                    mutate=lambda d, r="Bash(%s:*)" % spec: allow(d).append(r))
    expect_pass("allowlist: control, Bash(marvel get *) with a space wildcard passes C-set-2", "C-set-2",
                mutate=lambda d: allow(d).append("Bash(marvel get *)"))
    # The shipped file carries exactly the granted Bash lines.
    base = load_settings()
    shipped = sorted(r for r in (base or {}).get("permissions", {}).get("allow", []) if r.startswith("Bash("))
    record("allowlist: the shipped Bash allows are exactly the granted lines",
           shipped == sorted(GRANTED_LINES), "shipped %r" % shipped)


def test_failopen_types():
    """A value of the wrong type must fail, never be skipped."""
    expect_fail_all("fail-open 2: allow as a string fails C-set-2 and C-set-4", ["C-set-2", "C-set-4"],
                    mutate=lambda d: d.setdefault("permissions", {}).update({"allow": "Bash(*)"}))
    expect_fail_all("fail-open 2: allow as an object fails C-set-2 and C-set-4", ["C-set-2", "C-set-4"],
                    mutate=lambda d: d.setdefault("permissions", {}).update({"allow": {"Bash(*)": 1}}))
    expect_fail_all("fail-open 2: allow as a number fails C-set-2 and C-set-4", ["C-set-2", "C-set-4"],
                    mutate=lambda d: d.setdefault("permissions", {}).update({"allow": 7}))
    expect_fail_all("fail-open 2: a non-string allow entry fails C-set-2 and C-set-4", ["C-set-2", "C-set-4"],
                    mutate=lambda d: allow(d).append(5))
    expect_fail_all("fail-open 2: a null allow entry fails C-set-2 and C-set-4", ["C-set-2", "C-set-4"],
                    mutate=lambda d: allow(d).append(None))
    expect_fail_all("fail-open 2: permissions as a string fails C-set-2, C-set-3 and C-set-4",
                    ["C-set-2", "C-set-3", "C-set-4"],
                    mutate=lambda d: d.update({"permissions": "allow everything"}))
    expect_fail_all("fail-open 2: permissions as a list fails C-set-2, C-set-3 and C-set-4",
                    ["C-set-2", "C-set-3", "C-set-4"],
                    mutate=lambda d: d.update({"permissions": []}))
    expect_fail("fail-open 2: deny as a string fails C-set-3", "C-set-3",
                mutate=lambda d: d.setdefault("permissions", {}).update({"deny": "Read(~/.ssh/**)"}))
    expect_fail("fail-open 2: a non-string deny entry fails C-set-3", "C-set-3",
                mutate=lambda d: deny(d).append(3))
    expect_fail("fail-open 2: hooks as a string fails C-set-4", "C-set-4",
                mutate=lambda d: d.update({"hooks": "x"}))
    expect_fail("fail-open 2: a hook command that is a list fails C-set-4", "C-set-4",
                mutate=lambda d: d.update({"hooks": {"PreToolUse": [{"hooks": [
                    {"type": "command", "command": ["/opt/x/run"]}]}]}}))


def test_failopen_commands():
    """Every setting that runs a command is scanned for paths outside the tree."""
    for label, mut in (
        ("statusLine command, absolute", lambda d: d.update(
            {"statusLine": {"type": "command", "command": "/opt/x/status"}})),
        ("statusLine command, parent path", lambda d: d.update(
            {"statusLine": {"type": "command", "command": "../x/status"}})),
        ("statusLine command, home path", lambda d: d.update(
            {"statusLine": {"type": "command", "command": "~/status"}})),
        ("apiKeyHelper, absolute", lambda d: d.update({"apiKeyHelper": "/opt/x/key"})),
        ("apiKeyHelper, parent path", lambda d: d.update({"apiKeyHelper": "../x/key"})),
        ("awsAuthRefresh, absolute", lambda d: d.update({"awsAuthRefresh": "/opt/x/aws"})),
        ("awsCredentialExport, absolute", lambda d: d.update({"awsCredentialExport": "/opt/x/aws"})),
        ("otelHeadersHelper, absolute", lambda d: d.update({"otelHeadersHelper": "/opt/x/otel"})),
        ("a command nested under another key", lambda d: d.update(
            {"fileSuggestion": {"type": "command", "command": "/opt/x/files"}})),
        ("an apiKeyHelper that is not a string", lambda d: d.update({"apiKeyHelper": ["/opt/x/key"]})),
    ):
        expect_fail("fail-open 3: %s fails C-set-4" % label, "C-set-4", mutate=mut)
    expect_pass("fail-open 3: control, statusLine command inside the tree passes C-set-4", "C-set-4",
                mutate=lambda d: d.update({"statusLine": {"type": "command", "command": "./lab/status"}}))
    expect_pass("fail-open 3: control, apiKeyHelper inside the tree passes C-set-4", "C-set-4",
                mutate=lambda d: d.update({"apiKeyHelper": "./lab/key"}))


def test_failopen_unreadable():
    can_fail = hasattr(os, "geteuid") and os.geteuid() != 0

    def lock(proj):
        os.chmod(os.path.join(proj, "lab", "locked.txt"), 0)

    if can_fail:
        expect_fail_all("fail-open 4: an unreadable kit file fails C-set-1", ["C-set-1"],
                        extra_files={"lab/locked.txt": "x\n"}, setup=lock)
    else:
        record("fail-open 4: an unreadable kit file fails C-set-1 (skipped, running as root)", True)

    def lock_dir(proj):
        os.chmod(os.path.join(proj, "lab", "sub"), 0)

    if can_fail:
        expect_fail_all("fail-open 4: an unreadable kit directory fails C-set-1", ["C-set-1"],
                        extra_files={"lab/sub/x.txt": "x\n"}, setup=lock_dir)
    else:
        record("fail-open 4: an unreadable kit directory fails C-set-1 (skipped, running as root)", True)
    # Control: a readable tree with a subdirectory still passes.
    proj = make_project(extra_files={"lab/sub/x.txt": "x\n"})
    rc, out = check_project(proj)
    record("fail-open 4: control, a readable kit subdirectory passes C-set-1",
           line_status(out, "C-set-1") == "PASS", "got %r: %s" % (line_status(out, "C-set-1"), (out or "")[:200]))


def test_failopen_user_settings():
    can_fail = hasattr(os, "geteuid") and os.geteuid() != 0
    if not can_fail:
        record("fail-open 5: unreadable user settings fail C-set-5 (skipped, running as root)", True)
        return
    home = new_dir("home")
    write_user_settings(home, '{"theme": "dark"}\n')
    os.chmod(os.path.join(home, ".claude", "settings.json"), 0)
    snap = os.path.join(scratch_root, "snap-u1")
    rc1, out1 = run_check(["--user-snapshot", snap], home)
    record("fail-open 5: a snapshot of unreadable user settings exits 1",
           rc1 == 1 and "unreadable" in (out1 or "").lower(), "rc %r: %s" % (rc1, (out1 or "")[:200]))
    # Hand-written snapshot that records the unreadable state, then verify
    # while the file is still unreadable: the old code passed this.
    snap = os.path.join(scratch_root, "snap-u2")
    with open(snap, "w", encoding="utf-8") as fh:
        fh.write("unreadable:Permission denied\n")
    rc, out = run_check(["--user-verify", snap], home)
    record("fail-open 5: unreadable user settings before and after fail C-set-5",
           rc == 1 and line_status(out, "C-set-5") == "FAIL", "rc %r: %s" % (rc, (out or "")[:200]))
    # A readable snapshot against a file that became unreadable also fails.
    home2 = new_dir("home")
    write_user_settings(home2, '{"theme": "dark"}\n')
    snap = os.path.join(scratch_root, "snap-u3")
    run_check(["--user-snapshot", snap], home2)
    os.chmod(os.path.join(home2, ".claude", "settings.json"), 0)
    rc, out = run_check(["--user-verify", snap], home2)
    record("fail-open 5: user settings that became unreadable fail C-set-5",
           rc == 1 and line_status(out, "C-set-5") == "FAIL", "rc %r: %s" % (rc, (out or "")[:200]))
    # Control: a readable file still passes.
    home3 = new_dir("home")
    write_user_settings(home3, '{"theme": "dark"}\n')
    snap = os.path.join(scratch_root, "snap-u4")
    run_check(["--user-snapshot", snap], home3)
    rc, out = run_check(["--user-verify", snap], home3)
    record("fail-open 5: control, readable user settings still pass C-set-5",
           rc == 0 and line_status(out, "C-set-5") == "PASS", "rc %r: %s" % (rc, (out or "")[:200]))


def main():
    print("home for this run is a scratch directory under", scratch_root)
    for fn in (test_baseline, test_cset1, test_cset2, test_cset3, test_cset4,
               test_input_errors, test_cset5, test_no_writes_to_home,
               test_failopen_first_word, test_allowlist, test_failopen_types, test_failopen_commands,
               test_failopen_unreadable, test_failopen_user_settings):
        fn()
    passed = sum(1 for _, ok, _ in results if ok)
    failed = len(results) - passed
    print("%d passed, %d failed" % (passed, failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
