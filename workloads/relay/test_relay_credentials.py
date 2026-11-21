"""Tests for how the relay roles reach the managed bus.

The managed bus gives each seat a user and a password file in its environment:
DIRECTOR_NATS_USER and DIRECTOR_NATS_PASS_FILE, with NATS_URL. The nats command
line tool takes the user and password from NATS_USER and NATS_PASSWORD. Each
role must read the password file at the moment it runs nats, pass it only in
that process's environment, and never write the value anywhere: not to a log,
not to the pong file, not to the command line, not to its own output.

The tests run each role's script under sh with a stub `nats` on PATH. The stub
records what it was called with. No daemon, no bus, no network.

    python3 -I -B -m unittest discover -s workloads/relay -p 'test_*.py'
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

try:
    import tomllib
except ImportError:
    sys.stderr.write("test_relay_credentials.py needs Python 3.11 or newer (tomllib); this is %s\n" % sys.version.split()[0])
    sys.exit(2)

HERE = os.path.dirname(os.path.abspath(__file__))
SECRET = "pw-7c1e55a0-secret"
SECRET2 = "pw-9d02aa17-rotated"

# A stub nats. It records argv and the credentials it was handed, answers a sub
# with one line, and rotates the password file on its first sub so a later call
# shows whether the role read the file again.
STUB = """#!/bin/sh
d="$STUB_DIR"
echo "$*" >> "$d/argv.log"
echo "user=$NATS_USER pass=$NATS_PASSWORD args=$*" >> "$d/env.log"
case " $* " in
  *" sub "*)
    if [ -n "$STUB_HANG" ]; then echo $$ > "$d/sub.pid"; exec sleep 30; fi
    printf '%s' "$STUB_ROTATE" > "$DIRECTOR_NATS_PASS_FILE"
    case " $* " in
      *relay.ping*) echo "ping 1" ;;
      *relay.pong*) echo "pong 1" ;;
    esac
    ;;
esac
exit 0
"""


def role_script(name):
    with open(os.path.join(HERE, "manifest.toml"), "rb") as f:
        doc = tomllib.load(f)
    for role in doc["team"][0]["role"]:
        if role["name"] == name:
            return role["runtime"]["args"][1]
    raise AssertionError("no role %s in the manifest" % name)


class Run:
    """One role's script run to its end under a stub nats."""

    def __init__(self, test, role, extra=None):
        self.root = tempfile.mkdtemp(prefix="relay-cred.")
        test.addCleanup(shutil.rmtree, self.root, True)
        self.stub = os.path.join(self.root, "stub")
        self.bin = os.path.join(self.root, "bin")
        self.home = os.path.join(self.root, "home")
        for d in (self.stub, self.bin, self.home):
            os.mkdir(d)
        with open(os.path.join(self.bin, "nats"), "w") as f:
            f.write(STUB)
        os.chmod(os.path.join(self.bin, "nats"), 0o755)
        self.passfile = os.path.join(self.root, "seat.pass")
        with open(self.passfile, "w") as f:
            f.write(SECRET)
        env = {
            "PATH": self.bin + ":/usr/bin:/bin",
            "HOME": self.home,
            "TMPDIR": self.root,
            "STUB_DIR": self.stub,
            "STUB_ROTATE": SECRET2,
            "STUB_HANG": "",
            "MARVEL_SESSION": "relay-%s-g1-0" % role,
            "NATS_URL": "nats://127.0.0.1:14222",
            "DIRECTOR_NATS_USER": "relay",
            "DIRECTOR_NATS_PASS_FILE": self.passfile,
            "RELAY_MAX": "1",
            "RELAY_INTERVAL": "0",
            "RELAY_DRAIN": "0",
        }
        env.update(extra or {})
        # Output goes to a file, not a pipe: a process the role leaves behind would hold a pipe open
        # and make this wait for it.
        outpath = os.path.join(self.root, "role.out")
        with open(outpath, "wb") as outf:
            p = subprocess.run(["sh", "-c", role_script(role)], env=env, stdout=outf, stderr=subprocess.STDOUT, timeout=30)
        with open(outpath, errors="replace") as outf:
            self.out = outf.read()
        self.rc = p.returncode

    def read(self, *parts):
        path = os.path.join(self.root, *parts)
        return open(path, errors="replace").read() if os.path.exists(path) else ""

    def every_output(self):
        """All text the role left behind: its output, its logs and every file under home."""
        text = [self.out]
        for base, _dirs, files in os.walk(self.home):
            for name in files:
                text.append(open(os.path.join(base, name), errors="replace").read())
        return "\n".join(text)


class Credentials(unittest.TestCase):
    def test_pong_hands_nats_the_seat_user_and_password_in_its_environment(self):
        r = Run(self, "pong")
        env = r.read("stub", "env.log")
        self.assertIn("user=relay pass=%s" % SECRET, env, "no nats call carried the seat's user and password: %r" % env.replace(SECRET, "<pw>"))

    def test_ping_hands_nats_the_seat_user_and_password_in_its_environment(self):
        r = Run(self, "ping")
        env = r.read("stub", "env.log")
        self.assertIn("user=relay pass=", env, "ping never passed a user: %r" % env.replace(SECRET, "<pw>"))
        self.assertNotIn("user=relay pass= ", env, "ping passed an empty password")

    def test_the_password_is_read_again_at_each_call(self):
        # The stub rotates the file after the first sub, so the pub that follows
        # must carry the new value. A role that read the file once at start
        # would still send the old one.
        r = Run(self, "pong")
        pubs = [l for l in r.read("stub", "env.log").splitlines() if " pub " in l]
        self.assertTrue(pubs, "pong made no pub call")
        self.assertTrue(all(("pass=%s" % SECRET2) in l for l in pubs), "pub did not read the password file again: %r" % [l.replace(SECRET2, "<pw2>").replace(SECRET, "<pw>") for l in pubs])

    def test_the_password_value_is_in_no_output_log_file_or_command_line(self):
        for role in ("pong", "ping"):
            r = Run(self, role)
            argv = r.read("stub", "argv.log")
            for value in (SECRET, SECRET2):
                self.assertNotIn(value, argv, "%s put the password on the nats command line" % role)
                self.assertNotIn(value, r.every_output(), "%s wrote the password to its output or a file" % role)
            self.assertNotIn("--password", argv, "%s passes a password flag" % role)
            handed = r.read("stub", "env.log")
            self.assertIn("pass=pw-", handed, "%s never handed nats a password, so the absence above proves nothing" % role)

    def test_a_role_without_the_password_file_does_not_call_nats_with_a_blank_password(self):
        r = Run(self, "pong", {"DIRECTOR_NATS_PASS_FILE": "/nonexistent/seat.pass"})
        self.assertNotIn("pass= args", r.read("stub", "env.log"), "a nats call went out with an empty password")


class Subjects(unittest.TestCase):
    def test_every_subject_is_inside_the_team_namespace_the_bus_allows(self):
        for role in ("pong", "ping"):
            r = Run(self, role)
            argv = r.read("stub", "argv.log")
            self.assertIn("agent.lab.relay.ping", argv, "%s never used agent.lab.relay.ping" % role)
            self.assertNotIn(" lab.relay.", argv, "%s still uses a subject outside agent.lab.relay.>" % role)


class PingTrap(unittest.TestCase):
    def test_the_exit_trap_stops_the_nats_sub_itself(self):
        # The stub's sub writes its own pid and then stays up. When ping ends, its trap must
        # have killed that process, not only a subshell around it.
        r = Run(self, "ping", {"STUB_HANG": "1"})
        pidfile = os.path.join(r.stub, "sub.pid")
        self.assertTrue(os.path.exists(pidfile), "the ping role never started a nats sub")
        pid = int(open(pidfile).read().strip())
        try:
            alive = True
            for _ in range(20):
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    alive = False
                    break
                time.sleep(0.1)
            self.assertFalse(alive, "the nats sub (pid %d) outlived the ping role: the trap killed the wrong process" % pid)
        finally:
            try:
                os.kill(pid, 15)
            except ProcessLookupError:
                pass


class PongFile(unittest.TestCase):
    def test_pong_logs_each_ping_it_heard_and_answers_it(self):
        r = Run(self, "pong")
        log = r.read("home", "lab-run", "relay", "relay-pong-g1-0.log")
        self.assertIn("relay-pong-g1-0 heard ping 1", log)
        pubs = [l for l in r.read("stub", "argv.log").splitlines() if " pub " in " %s " % l]
        self.assertTrue(any("pong 1" in l for l in pubs), "pong did not answer: %r" % pubs)


if __name__ == "__main__":
    unittest.main()
