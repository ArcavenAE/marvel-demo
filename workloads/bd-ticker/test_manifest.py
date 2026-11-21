"""Offline checks for the bd-ticker workload (rung 8).

Run with Python 3.11 or newer:  env -i HOME=<scratch> TMPDIR=<scratch> PATH=$PATH python3 -I -B -m unittest discover -s workloads/bd-ticker -p 'test_*.py'

The manifest is parsed with tomllib. The role's wrapper script is then run under
sh with a stub `bd` on PATH that only records what it was called with. The real
bd is never run, and no daemon, bus or network is involved.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

try:
    import tomllib
except ImportError:
    sys.stderr.write("test_manifest.py needs Python 3.11 or newer (tomllib); this is %s\n" % sys.version.split()[0])
    sys.exit(2)

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "manifest.toml")
MARKER = "lab note from ticker seat"
LABEL = "lab-ticker-note"
SESSION = "bd-ticker-ticker-g1-0"

STUB = """#!/bin/sh
echo "$*" >> "$STUB_DIR/bd.log"
case "$1" in
  create) echo "orc-abc" ;;
esac
exit 0
"""


def load():
    if not os.path.exists(MANIFEST):
        raise AssertionError("workloads/bd-ticker/manifest.toml does not exist")
    with open(MANIFEST, "rb") as f:
        return tomllib.load(f)


def script():
    doc = load()
    roles = doc["team"][0]["role"]
    return doc, roles, roles[0]["runtime"]["args"][1]


class Seat:
    """The role's script run to its end, with the stub bd on PATH (or without it)."""

    def __init__(self, test, ticks=1, with_bd=True):
        self.root = tempfile.mkdtemp(prefix="bd-ticker.")
        test.addCleanup(shutil.rmtree, self.root, True)
        self.stub = os.path.join(self.root, "stub")
        self.bin = os.path.join(self.root, "bin")
        self.home = os.path.join(self.root, "home")
        for d in (self.stub, self.bin, self.home):
            os.mkdir(d)
        if with_bd:
            with open(os.path.join(self.bin, "bd"), "w") as f:
                f.write(STUB)
            os.chmod(os.path.join(self.bin, "bd"), 0o755)
        env = {
            "PATH": self.bin + ":/usr/bin:/bin",
            "HOME": self.home,
            "TMPDIR": self.root,
            "STUB_DIR": self.stub,
            "MARVEL_SESSION": SESSION,
            "BD_TICKER_MAX": str(ticks),
            "BD_TICKER_INTERVAL": "0",
        }
        _doc, _roles, text = script()
        p = subprocess.run(["sh", "-c", text], env=env, cwd=HERE, capture_output=True, timeout=30)
        self.out = p.stdout.decode(errors="replace") + p.stderr.decode(errors="replace")
        self.rc = p.returncode

    def bd_calls(self):
        path = os.path.join(self.stub, "bd.log")
        return open(path).read().splitlines() if os.path.exists(path) else []

    def log(self):
        path = os.path.join(self.home, "lab-run", "bd-ticker", SESSION + ".log")
        return open(path).read() if os.path.exists(path) else ""

    def files(self):
        out = []
        for base, _dirs, names in os.walk(self.home):
            for n in names:
                out.append(os.path.relpath(os.path.join(base, n), self.home))
        return sorted(out)


class Manifest(unittest.TestCase):
    def test_it_is_a_team_with_one_shell_role_that_restarts(self):
        doc, roles, _text = script()
        self.assertEqual(doc["workspace"]["name"], "lab")
        self.assertEqual(doc["team"][0]["name"], "bd-ticker")
        self.assertEqual(len(roles), 1)
        self.assertEqual(roles[0]["name"], "ticker")
        self.assertEqual(roles[0]["runtime"]["image"], "shell")
        self.assertEqual(roles[0]["restart_policy"], "always")


class Behavior(unittest.TestCase):
    def test_it_files_one_lab_issue_with_the_marker_title(self):
        s = Seat(self)
        creates = [c for c in s.bd_calls() if c.startswith("create")]
        self.assertEqual(len(creates), 1, "bd calls: %r" % s.bd_calls())
        self.assertIn("%s %s" % (MARKER, SESSION), creates[0])
        labels = creates[0].split("--labels ")[1].split()[0].split(",") if "--labels " in creates[0] else []
        self.assertIn("lab", labels, "the issue carries no lab label: %r" % creates[0])
        self.assertIn(LABEL, labels, "the issue carries no %s marker label: %r" % (LABEL, creates[0]))

    def test_it_files_once_however_many_ticks(self):
        s = Seat(self, ticks=3)
        creates = [c for c in s.bd_calls() if c.startswith("create")]
        self.assertEqual(len(creates), 1, "bd calls: %r" % s.bd_calls())

    def test_it_never_closes_or_edits_what_it_filed(self):
        s = Seat(self, ticks=3)
        verbs = {c.split()[0] for c in s.bd_calls() if c.split()}
        self.assertEqual(verbs, {"create"}, "the human closes the issue, so the seat uses only create: %r" % sorted(verbs))

    def test_it_records_the_filing_in_its_own_log(self):
        s = Seat(self)
        self.assertIn("%s filed orc-abc" % SESSION, s.log())

    def test_it_keeps_ticking_and_says_so_when_bd_is_missing(self):
        s = Seat(self, ticks=2, with_bd=False)
        self.assertEqual(s.rc, 0)
        self.assertIn("bd not found", s.log())

    def test_it_writes_only_under_its_own_state_directory(self):
        s = Seat(self, ticks=2)
        self.assertTrue(s.files(), "the seat wrote no file")
        for f in s.files():
            self.assertTrue(f.startswith("lab-run/bd-ticker/"), "wrote outside lab-run/bd-ticker: %s" % f)


if __name__ == "__main__":
    unittest.main()
