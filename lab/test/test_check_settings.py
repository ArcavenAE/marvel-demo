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
import re
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

def cls(rule):
    """Edit(./lab/run) -> Edit(./[Ll][Aa][Bb]/[Rr][Uu][Nn]): every letter of every
    path component becomes a character class; `.`, `/`, `-` and `*` stay literal.
    Bash rules and rules under ~ are not paths of the project and are left as they are."""
    tool, _, rest = rule.partition("(")
    spec = rest[:-1]
    if tool not in ("Edit", "Read") or not spec.startswith("./"):
        return rule
    out = []
    for ch in spec[2:]:
        out.append("[%s%s]" % (ch.upper(), ch.lower()) if ch.isalpha() else ch)
    return "%s(./%s)" % (tool, "".join(out))


def gi_regex(spec):
    """The subset of gitignore matching the lab's denies use: literal characters,
    [...] classes, ?, * (no slash) and ** (anything). Anchored at the project root;
    a match of a directory also covers what is under it."""
    i, out = 0, []
    while i < len(spec):
        ch = spec[i]
        if ch == "[":
            j = spec.index("]", i)
            out.append(spec[i:j + 1])
            i = j
        elif ch == "*" and spec[i:i + 2] == "**":
            out.append(".*")
            i += 1
        elif ch == "*":
            out.append("[^/]*")
        elif ch == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(ch))
        i += 1
    return re.compile("^" + "".join(out) + "(/.*)?$")


def gi_match(rule, path):
    """Does the deny `Edit(./spec)` match `path` (relative to the project root)?"""
    spec = rule.partition("(")[2][:-1]
    assert spec.startswith("./"), rule
    return bool(gi_regex(spec[2:]).match(path))


def alt_case(path):
    """A mixed-case spelling: letters alternate lower and upper."""
    out, flip = [], False
    for ch in path:
        if ch.isalpha():
            out.append(ch.upper() if flip else ch.lower())
            flip = not flip
        else:
            out.append(ch)
    return "".join(out)


PLAIN_DENY = [
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
    # Round 8: the report recipe runs lab/report, so the agent must not be able
    # to rewrite it under Edit(./lab/**); and the sentinel must not be readable
    # under Read(./lab/**), which is the denial rung 0b probes for.
    "Edit(./lab/report)",
    "Read(./lab/deny-probe)",
    # L8: just reads these names inside lab/ and refuses every `just lab`
    # recipe when one exists, so the agent must not be able to create them
    # under Edit(./lab/**).
    "Edit(./lab/mod.just)",
    "Edit(./lab/justfile)",
    "Edit(./lab/.justfile)",
]

# The path denies take the character-class form, so a path spelled in another
# letter case is still denied; entries that become the same string are kept once.
REQUIRED_DENY = []
for _r in PLAIN_DENY:
    if cls(_r) not in REQUIRED_DENY:
        REQUIRED_DENY.append(cls(_r))

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


def expect_pass(name, cid, mutate=None, extra_files=None):
    proj = make_project(mutate=mutate, extra_files=extra_files)
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
    # F1's settings carry no hooks at all, so even an in-tree hook command fails.
    expect_fail("C-set-4: a hook command inside the tree fails C-set-4 (no commands are allowed)", "C-set-4",
                mutate=lambda d: d.update(
                    {"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "./lab/hook-ok"}]}]}}))
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


def test_tool_allowlist():
    """C-set-2 allowlists tool names too: the only names that pass are the
    three F1 grants, Bash, Read and Edit, in exact case. Any other tool FAILs,
    whatever its spec looks like."""
    rules = [
        # The examples from the review.
        "PowerShell(*)", "WebFetch(domain:*)", "Agent(*)", "Skill(*)", "bash(sh -c:*)",
        # Write and other tools with a spec.
        "Write(./lab/x)", "Write(./lab/**)", "Write(*)", "NotebookEdit(./lab/x)",
        "MultiEdit(./lab/x)", "Task(x)", "WebSearch(x)", "WebFetch(x)", "Glob(*)", "Grep(x)",
        "TodoWrite(x)", "SlashCommand(x)", "KillShell(x)", "BashOutput(x)", "mcp__x__y(z)",
        "PowerShell(marvel get:*)", "Agent(marvel get)", "Skill(lab)",
        # Case variants and near misses of the three granted tools.
        "read(./lab/**)", "READ(./lab/**)", "rEad(./lab/**)", "edit(./lab/**)", "EDIT(./lab/**)",
        "bash(marvel get:*)", "BASH(marvel get:*)", "bAsh(marvel get:*)",
        "Bash (marvel get:*)", "Read (./lab/**)", "Edit (./lab/**)",
        "Bash(marvel get:*", "Read(./lab/**", "Read(./lab/**) x", "Bash(marvel get:*) x",
        "BashX(marvel get:*)", "Readx(./lab/**)", "Editor(./lab/**)", "(marvel get:*)", "()",
        "", " ",
    ]
    for rule in rules:
        expect_fail("tool allowlist: %r fails C-set-2" % rule, "C-set-2",
                    mutate=lambda d, r=rule: allow(d).append(r))
    # Controls: the shipped Read and Edit allows pass, and so do other
    # ./lab specs and all nine Bash grants (the last are covered above).
    base = load_settings()
    shipped = (base or {}).get("permissions", {}).get("allow", [])
    record("tool allowlist: the shipped allows hold Read(./lab/**) and Edit(./lab/**)",
           "Read(./lab/**)" in shipped and "Edit(./lab/**)" in shipped, "shipped %r" % shipped)
    expect_pass("tool allowlist: control, the shipped settings pass C-set-2", "C-set-2")
    expect_pass("tool allowlist: control, Read(./lab/notes.md) passes C-set-2", "C-set-2",
                mutate=lambda d: allow(d).append("Read(./lab/notes.md)"))
    expect_pass("tool allowlist: control, Edit(./lab/notes.md) passes C-set-2", "C-set-2",
                mutate=lambda d: allow(d).append("Edit(./lab/notes.md)"))
    # Dropping the shipped Read allow leaves the others passing: the check
    # judges what is present, it does not require the set.
    expect_pass("tool allowlist: control, a file without the Read allow still passes C-set-2", "C-set-2",
                mutate=lambda d: d["permissions"].update(
                    {"allow": [r for r in d["permissions"]["allow"] if r != "Read(./lab/**)"]}))


def test_key_allowlist():
    """M1: only `permissions` at the top level, only `allow` and `deny` inside it."""
    top = [
        ("enabledPlugins", {"enabledPlugins": {"x@y": True}}),
        ("extraKnownMarketplaces", {"extraKnownMarketplaces": {"m": {"source": {"source": "github", "repo": "o/r"}}}}),
        ("model", {"model": "x"}),
        ("outputStyle", {"outputStyle": "x"}),
        ("a schema key", {"$schema": "https://example.invalid/s.json"}),
        ("cleanupPeriodDays", {"cleanupPeriodDays": 1}),
        ("includeCoAuthoredBy", {"includeCoAuthoredBy": False}),
        ("an empty unknown key", {"x": {}}),
        ("a null unknown key", {"x": None}),
    ]
    for label, extra in top:
        expect_fail("key allowlist: top-level %s fails C-set-2" % label, "C-set-2",
                    mutate=lambda d, e=extra: d.update(e))
    inner = [
        ("additionalDirectories", {"additionalDirectories": ["~"]}),
        ("defaultMode acceptEdits", {"defaultMode": "acceptEdits"}),
        ("defaultMode plan", {"defaultMode": "plan"}),
        ("defaultMode auto", {"defaultMode": "auto"}),
        ("an ask list", {"ask": ["Bash(marvel get:*)"]}),
        ("disableBypassPermissionsMode", {"disableBypassPermissionsMode": "disable"}),
        ("an unknown key", {"x": 1}),
    ]
    for label, extra in inner:
        expect_fail("key allowlist: permissions.%s fails C-set-2" % label, "C-set-2",
                    mutate=lambda d, e=extra: d.setdefault("permissions", {}).update(e))
    # Hooks of the types that carry no `command` key.
    for label, hook in (("an http hook", {"type": "http", "url": "https://example.invalid/h"}),
                        ("an mcp_tool hook", {"type": "mcp_tool", "server": "s", "tool": "t"}),
                        ("a prompt hook", {"type": "prompt", "prompt": "x"})):
        expect_fail_all("key allowlist: %s fails C-set-2 and C-set-4" % label, ["C-set-2", "C-set-4"],
                        mutate=lambda d, h=hook: d.update({"hooks": {"PreToolUse": [{"hooks": [h]}]}}))
    # Controls: a file that holds only the two allowed blocks passes C-set-2,
    # whether or not it carries every field.
    expect_pass("key allowlist: control, the shipped keys pass C-set-2", "C-set-2")
    expect_pass("key allowlist: control, permissions with only allow passes C-set-2", "C-set-2",
                mutate=lambda d: d["permissions"].pop("deny"))
    expect_pass("key allowlist: control, permissions with only deny passes C-set-2", "C-set-2",
                mutate=lambda d: d["permissions"].pop("allow"))
    base = load_settings()
    ok = base is not None and sorted(base) == ["permissions"] and sorted(base["permissions"]) == ["allow", "deny"]
    record("key allowlist: the shipped file has exactly permissions{allow, deny}", ok,
           "keys %r" % (sorted(base) if base else None))


def test_no_commands():
    """M2: F1's settings carry no hooks, statusLine or helper command, so any
    of them FAILs C-set-4 and the output line says none are allowed."""
    cmds = [
        ("a hook running curl", {"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "curl https://example.invalid/x"}]}]}}),
        ("a hook running python3 -c", {"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "python3 -c \"import os\""}]}]}}),
        ("a hook chaining a command", {"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "./lab/h; curl x"}]}]}}),
        ("a hook inside the tree", {"hooks": {"PostToolUse": [{"hooks": [{"type": "command", "command": "./lab/h"}]}]}}),
        ("an empty hooks object", {"hooks": {}}),
        ("a statusLine inside the tree", {"statusLine": {"type": "command", "command": "./lab/s"}}),
        ("a statusLine running curl", {"statusLine": {"type": "command", "command": "curl x"}}),
        ("an apiKeyHelper inside the tree", {"apiKeyHelper": "./lab/k"}),
        ("an awsAuthRefresh inside the tree", {"awsAuthRefresh": "./lab/a"}),
        ("an awsCredentialExport inside the tree", {"awsCredentialExport": "./lab/a"}),
        ("an otelHeadersHelper inside the tree", {"otelHeadersHelper": "./lab/o"}),
        ("a nested command key", {"x": {"y": [{"command": "./lab/z"}]}}),
    ]
    for label, extra in cmds:
        expect_fail("no commands: %s fails C-set-4" % label, "C-set-4", mutate=lambda d, e=extra: d.update(e))
    proj = make_project()
    rc, out = check_project(proj)
    line = [l for l in (out or "").splitlines() if l.startswith("C-set-4")]
    record("no commands: the C-set-4 line says that no commands are allowed",
           bool(line) and "PASS" in line[0] and "none are allowed" in line[0], "line %r" % line)
    proj = make_project(mutate=lambda d: d.update({"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "./lab/h"}]}]}}))
    rc, out = check_project(proj)
    line = [l for l in (out or "").splitlines() if l.startswith("C-set-4")]
    record("no commands: a FAIL line says that none are allowed",
           bool(line) and "FAIL" in line[0] and "none are allowed" in line[0], "line %r" % line)


def test_lab_scope():
    """M3: a Read or Edit spec must start with ./lab/ ."""
    bad = ["./**", "./", ".", "./.claude/**", "./.claude/settings.json", "./lab", "./lab.lock", "./labx/**",
           "./lab/../x", "./lab/../../x", "./README.md", "./*", "./.git/**", "./**/x", "./lab/..", "lab/**",
           "**", "*", "", "./.lab/**", ".//lab/**", "./Lab/**", "./LAB/**"]
    for tool in ("Read", "Edit"):
        for spec in bad:
            expect_fail("lab scope: %s(%s) fails C-set-4" % (tool, spec), "C-set-4",
                        mutate=lambda d, r="%s(%s)" % (tool, spec): allow(d).append(r))
    for rule in ("Read(./lab/**)", "Edit(./lab/**)", "Read(./lab/notes.md)", "Edit(./lab/notes.md)",
                 "Read(./lab/sub/dir/**)", "Edit(./lab/a b.md)"):
        expect_pass("lab scope: control, %s passes C-set-4" % rule, "C-set-4",
                    mutate=lambda d, r=rule: allow(d).append(r))
    expect_pass("lab scope: control, the shipped settings pass C-set-4", "C-set-4")


def test_parsed_keys():
    """S1: C-set-1 also looks at parsed keys at any depth, so an escaped key
    that the raw bytes do not show still FAILs."""
    esc = "auto" + "\\u004d" + "ode"          # the key spelled with a JSON escape
    esc2 = "\\u0061uto" + "Mode"              # another escaped spelling
    raw_settings = '{"permissions": {"allow": [], "deny": []}, "%s": true}\n'
    expect_fail("parsed keys: an escaped key in the settings file fails C-set-1", "C-set-1",
                raw=raw_settings % esc)
    expect_fail("parsed keys: a second escaped spelling fails C-set-1", "C-set-1", raw=raw_settings % esc2)
    expect_fail("parsed keys: an escaped key nested in a list fails C-set-1", "C-set-1",
                raw='{"permissions": {"allow": [], "deny": []}, "x": [{"y": {"%s": 1}}]}\n' % esc)
    expect_fail("parsed keys: an escaped key in another JSON file fails C-set-1", "C-set-1",
                extra_files={"lab/other.json": '{"a": {"%s": 1}}\n' % esc})
    expect_fail("parsed keys: an escaped key in a file without a .json name fails C-set-1", "C-set-1",
                extra_files={"lab/other.txt": '{"%s": 1}\n' % esc})
    expect_fail("parsed keys: an escaped key in a top-level JSON list fails C-set-1", "C-set-1",
                extra_files={"lab/list.json": '[{"%s": 1}]\n' % esc})
    # Controls: benign JSON, an escaped benign key, a similar key and a
    # non-JSON file all pass.
    expect_pass("parsed keys: control, another JSON file with benign keys passes C-set-1", "C-set-1",
                extra_files={"lab/ok.json": '{"a": {"b": [1, 2, {"c": 3}]}}\n'})
    expect_pass("parsed keys: control, an escaped benign key passes C-set-1", "C-set-1",
                extra_files={"lab/ok2.json": '{"\\u0061": 1}\n'})
    expect_pass("parsed keys: control, a similar key passes C-set-1", "C-set-1",
                extra_files={"lab/ok3.json": '{"auto": 1, "mode": 2, "Automode": 3}\n'})
    expect_pass("parsed keys: control, text that is not JSON passes C-set-1", "C-set-1",
                extra_files={"lab/ok.txt": "{not json at all\n"})


def test_override_files():
    """Round 5: Claude Code applies .claude/settings.local.json over the shared
    file and reads MCP servers from .mcp.json, so either file anywhere in the
    kit FAILs C-set-2, whatever it holds."""
    benign = "{}\n"
    harmful = '{"permissions": {"allow": ["Bash(*)"]}, "enabledPlugins": {"x@y": true}}\n'
    mcp = '{"mcpServers": {"s": {"command": "x"}}}\n'
    places = ["", ".claude/", "lab/", "lab/sub/deep/", "x/.claude/", ".claude/lab/"]
    for name, bodies in (("settings.local.json", (benign, harmful)), (".mcp.json", (benign, mcp))):
        for place in places:
            for body in bodies:
                kind = "benign" if body == benign else "harmful"
                expect_fail("override files: %s%s (%s) fails C-set-2" % (place, name, kind), "C-set-2",
                            extra_files={place + name: body})
    # Empty file, and a file that is not JSON: existence alone FAILs.
    expect_fail("override files: an empty .claude/settings.local.json fails C-set-2", "C-set-2",
                extra_files={".claude/settings.local.json": ""})
    expect_fail("override files: a non-JSON .mcp.json fails C-set-2", "C-set-2",
                extra_files={".mcp.json": "not json\n"})
    # Case variants resolve to the same file on a case-insensitive filesystem.
    for rel in (".claude/Settings.local.json", ".claude/SETTINGS.LOCAL.JSON", ".claude/settings.LOCAL.json",
                ".MCP.json", ".Mcp.JSON"):
        expect_fail("override files: the case variant %s fails C-set-2" % rel, "C-set-2",
                    extra_files={rel: benign})

    def link_mcp(proj):
        os.symlink("/nonexistent/target", os.path.join(proj, ".mcp.json"))

    def dir_mcp(proj):
        os.makedirs(os.path.join(proj, "lab", ".mcp.json"))

    def link_local(proj):
        os.symlink("../lab/x", os.path.join(proj, ".claude", "settings.local.json"))

    expect_fail_all("override files: a broken symlink named .mcp.json fails C-set-2", ["C-set-2"], setup=link_mcp)
    expect_fail_all("override files: a directory named .mcp.json fails C-set-2", ["C-set-2"], setup=dir_mcp)
    expect_fail_all("override files: a symlink named settings.local.json fails C-set-2", ["C-set-2"],
                    setup=link_local)
    if hasattr(os, "geteuid") and os.geteuid() != 0:
        def hide(proj):
            os.chmod(os.path.join(proj, "lab", "hidden"), 0)

        expect_fail_all("override files: an unreadable directory that could hide one fails C-set-2", ["C-set-2"],
                        extra_files={"lab/hidden/x.txt": "x\n"}, setup=hide)
    else:
        record("override files: an unreadable directory that could hide one fails C-set-2 (skipped, root)", True)
    # Controls: look-alike names and the shipped tree pass C-set-2.
    for rel in (".claude/settings.local.json.example", ".claude/settings.local.json.bak",
                ".claude/settings.local.json~", "settings.local.jsonx", "xsettings.local.json",
                "mcp.json", ".claude/mcp.json", ".mcp.json.example", "my.mcp.json", ".mcp.jsonl",
                ".claude/settings.json.local", ".claude/local.settings.json", "lab/settings.local",
                ".claude/settings.local", ".mcp", "lab/mcp.json"):
        expect_pass("override files: control, %s passes C-set-2" % rel, "C-set-2",
                    extra_files={rel: benign})
    expect_pass("override files: control, the shipped tree passes C-set-2", "C-set-2")
    # The real tree carries neither file.
    found = []
    for dp, dn, fn in os.walk(REPO):
        dn[:] = [d for d in dn if d != ".git"]
        for f in dn + fn:
            if f.lower() in ("settings.local.json", ".mcp.json"):
                found.append(os.path.join(dp, f))
    record("override files: the real kit tree has neither file, and has the settings file",
           not found and os.path.exists(SETTINGS), "found %r" % found)


def test_fold_override_names():
    """Round 6: an APFS volume folds U+017F (LONG S) onto s, so a file named
    with it opens as settings.local.json or .mcp.json. The match uses
    casefold, which folds it, not lower, which does not. Measured on this
    volume: of every character whose case, canonical or compatibility form
    reaches a letter of the two names, only U+017F resolves to the file."""
    long_s = "\u017f"
    names = ("settings.local.json", ".mcp.json")
    # Every s position of both names, at the project root and in .claude/.
    for name in names:
        for i, ch in enumerate(name):
            if ch != "s":
                continue
            variant = name[:i] + long_s + name[i + 1:]
            for place in ("", ".claude/", "lab/sub/"):
                expect_fail("fold: U+017F at position %d of %s%s fails C-set-2" % (i, place, name), "C-set-2",
                            extra_files={place + variant: "{}\n"})
    # Mixed spellings: long s together with upper case and with a plain case variant.
    for rel in ("\u017fETTINGS.LOCAL.JSON", "\u017fettings.local.JSON", ".claude/\u017fETTINGS.local.json",
                ".MCP.J\u017fON", ".mcp.j\u017fon", ".claude/.mcp.j\u017fon"):
        expect_fail("fold: the mixed spelling %r fails C-set-2" % rel, "C-set-2",
                    extra_files={rel: "{}\n"})
    # A link and a directory with the folded name fail the same way.
    def link(proj):
        os.symlink("../lab/x", os.path.join(proj, ".claude", "\u017fettings.local.json"))

    def folder(proj):
        os.makedirs(os.path.join(proj, "lab", ".mcp.j\u017fon"))

    expect_fail_all("fold: a link named with U+017F fails C-set-2", ["C-set-2"], setup=link)
    expect_fail_all("fold: a directory named with U+017F fails C-set-2", ["C-set-2"], setup=folder)
    # Controls. U+212A KELVIN SIGN lowers to k, but neither name has a k, so
    # it cannot reach them; a name that merely carries it is a different file.
    # Full-width and other compatibility forms do not resolve on the measured
    # volume, so they pass: the check does not widen past the folds that do.
    for rel in ("settings.local.json\u212a", "\u212aettings.local.json", "settings.local.js\u212an",
                "\uff53ettings.local.json", ".mcp.j\uff53on", "settings.local.j\u00dfon",
                "settings.local.\u0131json", "\u0131settings.local.json", "settings.local.json\u017f",
                "\u017fsettings.local.json", ".mcp.json\u017f", "x.\u017fmcp.json"):
        expect_pass("fold: control, %r passes C-set-2" % rel, "C-set-2", extra_files={rel: "{}\n"})
    # The property behind the choice, so a change of function shows here.
    record("fold: casefold maps U+017F onto s and lower does not (the reason for the choice)",
           ("\u017fettings.local.json".casefold() == "settings.local.json"
            and "\u017fettings.local.json".lower() != "settings.local.json"),
           "casefold or lower behaves differently in this Python")


def test_round8_denies():
    """Edit(./lab/**) is allowed and `just lab report` runs lab/report, so
    lab/report must be denied for Edit; the sentinel must be denied for Read.
    Both are required denies (the removal mutants run in test_cset3), and
    neither may also appear as an allow."""
    shipped = (load_settings() or {}).get("permissions", {})
    for rule in ("Edit(./lab/report)", "Read(./lab/deny-probe)"):
        rule = cls(rule)
        record("round 8: the shipped deny list holds %s" % rule, rule in shipped.get("deny", []),
               "deny is %r" % shipped.get("deny"))
        expect_fail("round 8: %s as an allow fails C-set-2 (allow equal to a deny)" % rule, "C-set-2",
                    mutate=lambda d, r=rule: allow(d).append(r))
    record("round 8: the shipped deny list has 25 entries", len(shipped.get("deny", [])) == 25,
           "count %r" % len(shipped.get("deny", [])))
    # Removing only one of the two leaves C-set-3 FAIL naming the other.
    for rule in ("Edit(./lab/report)", "Read(./lab/deny-probe)"):
        rule = cls(rule)
        proj = make_project(mutate=lambda d, r=rule: d["permissions"].update(
            {"deny": [x for x in d["permissions"]["deny"] if x != r]}))
        rc, out = check_project(proj)
        line = [l for l in (out or "").splitlines() if l.startswith("C-set-3")]
        record("round 8: without %s the C-set-3 line FAILs and names it" % rule,
               rc == 1 and bool(line) and "FAIL" in line[0] and rule in line[0], "line %r" % line)
    # Related controls: allows next to the denied files stay fine.
    expect_pass("round 8: control, Edit(./lab/reports.md) as an allow passes C-set-2", "C-set-2",
                mutate=lambda d: allow(d).append("Edit(./lab/reports.md)"))
    expect_pass("round 8: control, Read(./lab/deny-probe.md) as an allow passes C-set-2", "C-set-2",
                mutate=lambda d: allow(d).append("Read(./lab/deny-probe.md)"))
    expect_pass("round 8: control, Read(./lab/report) as an allow passes C-set-2", "C-set-2",
                mutate=lambda d: allow(d).append("Read(./lab/report)"))
    expect_pass("round 8: control, the shipped settings pass C-set-3", "C-set-3")


def test_justfile_denies():
    """L8: lab/mod.just, lab/justfile and lab/.justfile each make just refuse
    every `just lab` recipe, and Edit(./lab/**) would let the agent create
    them. Each is a required deny (the removal mutants run in test_cset3), is
    in the shipped file, and may not also be an allow."""
    shipped = (load_settings() or {}).get("permissions", {})
    for rule in ("Edit(./lab/mod.just)", "Edit(./lab/justfile)", "Edit(./lab/.justfile)", "Edit(./lab/Justfile)"):
        rule = cls(rule)
        record("justfile denies: the shipped deny list holds %s" % rule, rule in shipped.get("deny", []),
               "deny is %r" % shipped.get("deny"))
        expect_fail("justfile denies: %s as an allow fails C-set-2 (allow equal to a deny)" % rule, "C-set-2",
                    mutate=lambda d, r=rule: allow(d).append(r))
        proj = make_project(mutate=lambda d, r=rule: d["permissions"].update(
            {"deny": [x for x in d["permissions"]["deny"] if x != r]}))
        rc, out = check_project(proj)
        line = [l for l in (out or "").splitlines() if l.startswith("C-set-3")]
        record("justfile denies: without %s the C-set-3 line FAILs and names it" % rule,
               rc == 1 and bool(line) and "FAIL" in line[0] and rule in line[0], "line %r" % line)
    # Look-alikes stay allowed.
    for rule in ("Edit(./lab/mod.justx)", "Edit(./lab/justfiles)", "Read(./lab/justfile)", "Read(./lab/mod.just)", "Read(./lab/Justfile)", "Edit(./lab/Justfiles)"):
        expect_pass("justfile denies: control, %s as an allow passes C-set-2" % rule, "C-set-2",
                    mutate=lambda d, r=rule: allow(d).append(r))


def test_roots_of_trust():
    """The files the digest check cannot cover, because they do the checking
    or choose what runs, each carry an Edit deny that check-settings requires:
    lab/run, lab.lock, lab/check-settings (already required), and lab.just,
    the justfile and .claude/settings.json (outside the Edit(./lab/**) allow,
    so without a deny they would prompt, not refuse). Each is in the shipped
    file, may not also be an allow, and its removal makes C-set-3 FAIL."""
    shipped = (load_settings() or {}).get("permissions", {})
    for rule in ("Edit(./lab/run)", "Edit(./lab.lock)", "Edit(./lab/check-settings)",
                 "Edit(./lab.just)", "Edit(./justfile)", "Edit(./.claude/settings.json)",
                 "Edit(./.git/config)", "Edit(./.claude/settings.local.json)"):
        rule = cls(rule)
        record("roots: the shipped deny list holds %s" % rule, rule in shipped.get("deny", []),
               "deny is %r" % shipped.get("deny"))
        expect_fail("roots: %s as an allow fails C-set-2 (allow equal to a deny)" % rule, "C-set-2",
                    mutate=lambda d, r=rule: allow(d).append(r))
        proj = make_project(mutate=lambda d, r=rule: d["permissions"].update(
            {"deny": [x for x in d["permissions"]["deny"] if x != r]}))
        rc, out = check_project(proj)
        line = [l for l in (out or "").splitlines() if l.startswith("C-set-3")]
        record("roots: without %s the C-set-3 line FAILs and names it" % rule,
               rc == 1 and bool(line) and "FAIL" in line[0] and rule in line[0], "line %r" % line)
    for rule in ("Edit(./lab.justx)", "Edit(./justfiles)", "Read(./lab.just)", "Read(./justfile)",
                 "Read(./.claude/settings.json)", "Read(./.git/config)", "Edit(./.git/config.bak)",
                 "Read(./.claude/settings.local.json)", "Edit(./.claude/settings.local.json.bak)"):
        expect_pass("roots: control, %s as an allow passes C-set-2" % rule, "C-set-2",
                    mutate=lambda d, r=rule: allow(d).append(r))


def test_case_proof():
    """Every path deny holds whatever letter case the path is spelled in. Claude
    Code's own matcher is not run; a gitignore matcher in this file stands in for
    it, and a pattern that matches each spelling is the proof."""
    shipped = (load_settings() or {}).get("permissions", {})
    deny_list = shipped.get("deny", [])
    paths = [
        ("Edit(./lab/check-settings)", "lab/check-settings"),
        ("Edit(./lab/run)", "lab/run"),
        ("Edit(./lab.lock)", "lab.lock"),
        ("Edit(./lab/HARNESS.md)", "lab/HARNESS.md"),
        ("Edit(./lab/report)", "lab/report"),
        ("Edit(./lab/mod.just)", "lab/mod.just"),
        ("Edit(./lab/justfile)", "lab/justfile"),
        ("Edit(./lab/.justfile)", "lab/.justfile"),
        ("Edit(./lab/Justfile)", "lab/Justfile"),
        ("Edit(./lab.just)", "lab.just"),
        ("Edit(./justfile)", "justfile"),
        ("Edit(./.claude/settings.json)", ".claude/settings.json"),
        ("Edit(./.git/config)", ".git/config"),
        ("Edit(./.claude/settings.local.json)", ".claude/settings.local.json"),
        ("Edit(./lab/test/**)", "lab/test/a/b.sh"),
        ("Read(./lab/deny-probe)", "lab/deny-probe"),
    ]
    # The matcher itself first: a wrong matcher would make every line below vacuous.
    record("matcher: a class matches both cases", gi_match("Edit(./[Rr]un)", "run") and gi_match("Edit(./[Rr]un)", "Run"))
    record("matcher: a class does not match another letter", not gi_match("Edit(./[Rr]un)", "sun"))
    record("matcher: a plain pattern does not match another case", not gi_match("Edit(./run)", "RUN"))
    record("matcher: a longer name does not match", not gi_match("Edit(./[Rr]un)", "runs"))
    record("matcher: ** crosses directories", gi_match("Edit(./t/**)", "t/a/b"))
    # Every path deny is held in the class form, and matches each spelling.
    for rule, path in paths:
        want = cls(rule)
        record("case proof: the shipped deny list holds %s" % want, want in deny_list, "deny is %r" % deny_list)
        for label, spelling in (("plain", path), ("upper", path.upper()), ("mixed", alt_case(path)),
                                ("directory in another case", "/".join([path.split("/")[0].upper()] + path.split("/")[1:]))):
            record("case proof: %s matches %s spelling %s" % (want, label, spelling), gi_match(want, spelling))
    # The literal expected form, written out once, not computed by cls().
    record("case proof: the justfile deny is written out",
           "Edit(./[Ll][Aa][Bb]/[Jj][Uu][Ss][Tt][Ff][Ii][Ll][Ee])" in deny_list)
    # A look-alike is not matched.
    record("case proof: lab/runs is not denied by the lab/run class", not gi_match(cls("Edit(./lab/run)"), "lab/runs"))
    record("case proof: lab/tests is not denied by the lab/test/** class", not gi_match(cls("Edit(./lab/test/**)"), "lab/tests"))
    # check-settings requires the class forms: plain-only and last-component-only both FAIL C-set-3.
    def plain_only(d):
        d["permissions"]["deny"] = [r for r in d["permissions"]["deny"] if r not in REQUIRED_DENY or not r.startswith(("Edit(", "Read(./"))] \
            + [p for p, _ in paths]
    expect_fail("case proof: plain path denies alone fail C-set-3", "C-set-3", mutate=plain_only)
    def last_component_only(d):
        deny_new = []
        for r in d["permissions"]["deny"]:
            if r == cls("Edit(./lab/Justfile)"):
                r = "Edit(./lab/[Jj][Uu][Ss][Tt][Ff][Ii][Ll][Ee])"
            deny_new.append(r)
        d["permissions"]["deny"] = deny_new
    expect_fail("case proof: a class on the last component only fails C-set-3", "C-set-3", mutate=last_component_only)
    proj = make_project(mutate=last_component_only)
    rc, out = check_project(proj)
    line = [l for l in (out or "").splitlines() if l.startswith("C-set-3")]
    record("case proof: the C-set-3 line names the missing class form",
           rc == 1 and bool(line) and cls("Edit(./lab/Justfile)") in line[0], "line %r" % line)


def test_no_allowed_bash_writes_a_root():
    """No allowed Bash pattern can write a root. The shipped Bash allows are
    exactly the nine granted lines, and every writer-shaped or wider Bash
    allow fails C-set-2."""
    shipped = (load_settings() or {}).get("permissions", {})
    bash = sorted(r for r in shipped.get("allow", []) if r.startswith("Bash("))
    want = sorted("Bash(%s:*)" % w for w in (
        "marvel get", "marvel doctor", "marvel capture", "marvel events",
        "bd show", "bd ready", "just lab rung", "just lab check", "just lab report"))
    record("no writer: the shipped Bash allows are exactly the nine granted lines", bash == want, "got %r" % bash)
    for rule in ("Bash(tee:*)", "Bash(cp:*)", "Bash(mv:*)", "Bash(sed -i:*)", "Bash(git checkout:*)",
                 "Bash(git:*)", "Bash(just:*)", "Bash(just lab:*)", "Bash(just --justfile x lab report:*)",
                 "Bash(just lab report > lab.lock:*)", "Bash(lab/run:*)", "Bash(./lab/run:*)",
                 "Bash(marvel:*)", "Bash(bd:*)", "Bash(bd update:*)", "Bash(touch:*)", "Bash(dd:*)",
                 "Bash(install:*)", "Bash(ln:*)", "Bash(perl:*)", "Bash(awk:*)", "Bash(just lab report;touch lab.lock:*)"):
        expect_fail("no writer: %s as an allow fails C-set-2" % rule, "C-set-2",
                    mutate=lambda d, r=rule: allow(d).append(r))


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
    expect_fail("fail-open 3: a statusLine command inside the tree fails C-set-4 (none are allowed)", "C-set-4",
                mutate=lambda d: d.update({"statusLine": {"type": "command", "command": "./lab/status"}}))
    expect_fail("fail-open 3: an apiKeyHelper inside the tree fails C-set-4 (none are allowed)", "C-set-4",
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
               test_failopen_first_word, test_allowlist, test_tool_allowlist, test_key_allowlist, test_no_commands,
               test_lab_scope, test_parsed_keys, test_override_files, test_fold_override_names,
               test_round8_denies, test_justfile_denies, test_roots_of_trust, test_case_proof,
               test_no_allowed_bash_writes_a_root, test_failopen_types, test_failopen_commands,
               test_failopen_unreadable, test_failopen_user_settings):
        fn()
    passed = sum(1 for _, ok, _ in results if ok)
    failed = len(results) - passed
    print("%d passed, %d failed" % (passed, failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
