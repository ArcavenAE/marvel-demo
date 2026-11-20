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


def main():
    print("home for this run is a scratch directory under", scratch_root)
    for fn in (test_baseline, test_cset1, test_cset2, test_cset3, test_cset4,
               test_input_errors, test_cset5, test_no_writes_to_home):
        fn()
    passed = sum(1 for _, ok, _ in results if ok)
    failed = len(results) - passed
    print("%d passed, %d failed" % (passed, failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
