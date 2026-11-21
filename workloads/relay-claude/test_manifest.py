"""Offline checks for the relay-claude workload (rung 10, relay part ii).

Run with Python 3.11 or newer:  env -i HOME=<scratch> TMPDIR=<scratch> PATH=$PATH python3 -I workloads/relay-claude/test_manifest.py

Nothing here starts a seat, calls a model or opens a socket. The manifest is
parsed with tomllib. Each role's wrapper script is then run once, under `sh`,
with a stand-in `claude` that only writes its arguments to a file, so the test
can read the --mcp-config value the real command would receive and parse it as
JSON. The stand-in is the only `claude` on PATH; the real one is never run.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
try:
    import tomllib
except ImportError:
    sys.stderr.write("test_manifest.py needs Python 3.11 or newer (tomllib); this is %s\n" % sys.version.split()[0])
    sys.exit(2)

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MANIFEST = os.path.join(HERE, "manifest.toml")
README = os.path.join(HERE, "README.md")
TABLE = os.path.join(REPO, "workloads", "README.md")

passed = 0
failed = 0


def record(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print("  ok    %s" % name)
    else:
        failed += 1
        print("  FAIL  %s  -- %s" % (name, detail))


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


# Words the repo bans, built from parts so this file does not contain them.
BANNED = ["compre" + "hensive", "complete" + "ly", "ro" + "bust", "seam" + "less", "cutting" + "-edge", "best of " + "breed"]
EM_DASH = chr(0x2014)
BYPASS = ["dangerously", "bypass" + "Permissions", "dont" + "Ask", "--permission-mode", "skip-permissions"]
PER_DIR = [".mcp.json", "claude mcp", "settings.local", "~/.claude", ".claude.json", "--scope", "mcp add", "enabledMcp"]

mtext = read(MANIFEST)
rtext = read(README)
ttext = read(TABLE)

record("the manifest exists", mtext is not None, "no workloads/relay-claude/manifest.toml")
record("the README exists", rtext is not None, "no workloads/relay-claude/README.md")

doc = None
if mtext is not None:
    try:
        doc = tomllib.loads(mtext)
    except tomllib.TOMLDecodeError as exc:
        record("the manifest parses as TOML", False, str(exc))
    else:
        record("the manifest parses as TOML", True)

roles = {}
if doc is not None:
    ws = doc.get("workspace", {})
    record("the workspace is lab", ws.get("name") == "lab", "workspace %r" % ws)
    teams = doc.get("team", [])
    record("one team, relay-claude", len(teams) == 1 and teams[0].get("name") == "relay-claude",
           "teams %r" % [t.get("name") for t in teams])
    for t in teams:
        for r in t.get("role", []):
            roles[r.get("name")] = r
    record("two roles, asker and answerer", sorted(roles) == ["answerer", "asker"], "roles %r" % sorted(roles))
else:
    record("one team, relay-claude", False, "no manifest")
    record("two roles, asker and answerer", False, "no manifest")

PLACEHOLDER_SHIM = "director-mcp"


def run_wrapper(role):
    """Run the role's wrapper with a stand-in claude; return (argv, env) or None."""
    rt = role.get("runtime", {})
    scratch = tempfile.mkdtemp(prefix="relay-claude.", dir=os.environ.get("TMPDIR"))
    bindir = os.path.join(scratch, "bin")
    os.makedirs(bindir)
    out = os.path.join(scratch, "argv.txt")
    envf = os.path.join(scratch, "env.txt")
    stub = os.path.join(bindir, "claude")
    with open(stub, "w", encoding="utf-8") as f:
        f.write("#!/bin/sh\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done > \"$ARGV_OUT\"\nenv > \"$ENV_OUT\"\n")
    os.chmod(stub, 0o755)
    sh = shutil.which("sh") or "/bin/sh"
    env = {
        "PATH": bindir + os.pathsep + "/usr/bin" + os.pathsep + "/bin",
        "HOME": scratch,
        "TMPDIR": scratch,
        "ARGV_OUT": out,
        "ENV_OUT": envf,
        "MARVEL_SESSION": "relay-claude-%s-g1-0" % role.get("name"),
        "MARVEL_ROLE": str(role.get("name")),
        "MARVEL_TEAM": "relay-claude",
        "MARVEL_WORKSPACE": "lab",
        "MARVEL_FIRST_PROMPT": "first message from marvel",
    }
    env.update({k: str(v) for k, v in rt.get("env", {}).items()})
    cmd = [rt.get("command", "")] + list(rt.get("args", []))
    if cmd[0] != "sh":
        return None
    cmd[0] = sh
    cmd = cmd + ["--model-flag-from-marvel", "x"]
    try:
        subprocess.run(cmd, env=env, cwd=scratch, check=False, timeout=20,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return None
    try:
        with open(out, "rb") as f:
            argv = [a.decode("utf-8") for a in f.read().split(b"\0") if a != b""]
        with open(envf, encoding="utf-8") as f:
            seen = dict(l.rstrip("\n").split("=", 1) for l in f if "=" in l)
    except OSError:
        return None
    return argv, seen


for name in ("asker", "answerer"):
    role = roles.get(name)
    if role is None:
        for what in ("is a claude image", "runs through sh -c", "ends in exec claude with the strict flag pair",
                     "passes marvel's own flags through", "hands claude one mcp-config that parses as JSON",
                     "the mcp-config names the director shim and its five variables",
                     "the shim command is a bare name, not a path", "sets DIRECTOR_ROLE in runtime.env",
                     "asks for plan mode", "has a first prompt"):
            record("%s %s" % (name, what), False, "no such role")
        continue
    rt = role.get("runtime", {})
    record("%s is a claude image" % name, rt.get("image") == "claude", "image %r" % rt.get("image"))
    args = rt.get("args", [])
    script = args[1] if len(args) > 1 else ""
    record("%s runs through sh -c" % name, rt.get("command") == "sh" and args[:1] == ["-c"], "command %r args %r" % (rt.get("command"), args[:1]))
    flat = re.sub(r"\s+", " ", script)
    record("%s ends in exec claude with the strict flag pair" % name,
           "exec claude" in flat and "--strict-mcp-config" in flat and "--mcp-config" in flat
           and flat.index("--strict-mcp-config") < flat.index("--mcp-config") + len("--mcp-config"),
           "script %r" % flat[:200])
    record("%s sets DIRECTOR_ROLE in runtime.env" % name, rt.get("env", {}).get("DIRECTOR_ROLE") == name,
           "env %r" % rt.get("env"))
    record("%s asks for plan mode and no bypass" % name, role.get("permissions") == "plan", "permissions %r" % role.get("permissions"))
    prompt = rt.get("prompt", "")
    record("%s has a first prompt" % name, isinstance(prompt, str) and len(prompt) > 40, "prompt %r" % prompt)
    ran = run_wrapper(role)
    if ran is None:
        for what in ("passes marvel's own flags through", "hands claude one mcp-config that parses as JSON",
                     "the mcp-config names the director shim and its five variables",
                     "the shim command is a bare name, not a path"):
            record("%s %s" % (name, what), False, "the wrapper did not run with the stand-in claude")
        continue
    argv, seen = ran
    record("%s passes marvel's own flags through" % name, "--model-flag-from-marvel" in argv and "x" in argv, "argv %r" % argv)
    record("%s hands claude --strict-mcp-config once" % name, argv.count("--strict-mcp-config") == 1, "argv %r" % argv)
    idx = [i for i, a in enumerate(argv) if a == "--mcp-config"]
    cfg = None
    if len(idx) == 1 and idx[0] + 1 < len(argv):
        try:
            cfg = json.loads(argv[idx[0] + 1])
        except ValueError:
            cfg = None
    record("%s hands claude one mcp-config that parses as JSON" % name, cfg is not None, "argv %r" % argv)
    srv = ((cfg or {}).get("mcpServers") or {})
    record("%s mcp-config holds exactly the director server" % name, list(srv) == ["director"], "servers %r" % list(srv))
    d = srv.get("director", {})
    envd = d.get("env", {})
    want = {"DIRECTOR_AGENT_ID": "relay-claude-%s-g1-0" % name, "DIRECTOR_ROLE": name,
            "DIRECTOR_TEAM": "relay-claude", "DIRECTOR_WORKSPACE": "lab"}
    record("%s the mcp-config names the director shim and its variables" % name,
           all(envd.get(k) == v for k, v in want.items()) and str(envd.get("NATS_URL", "")).startswith("nats://"),
           "env %r" % envd)
    cmdname = d.get("command", "")
    record("%s the shim command is a bare name, not a path" % name, cmdname == PLACEHOLDER_SHIM, "command %r" % cmdname)
    record("%s does not set the global tier" % name, not any(k.startswith("DIRECTOR_GLOBAL") for k in envd), "env %r" % envd)
    first = argv[-1] if argv else ""
    record("%s hands the first message to claude" % name, "first message from marvel" in argv or (prompt and prompt in argv), "argv %r" % argv)
    record("%s names the session, so claude -n gets it" % name, "-n" in argv and "relay-claude-%s-g1-0" % name in argv, "argv %r" % argv)

asker = roles.get("asker", {}).get("runtime", {}).get("prompt", "")
record("the asker's prompt names the answerer's address",
       "agent://relay-claude/relay-claude-answerer-g1-0" in asker, "prompt %r" % asker)
record("the asker's prompt sends one message and stops", "one" in asker.lower() and "stop" in asker.lower(), "prompt %r" % asker)
answerer = roles.get("answerer", {}).get("runtime", {}).get("prompt", "")
record("the answerer's prompt says to reply once", "reply" in answerer.lower() and "once" in answerer.lower(), "prompt %r" % answerer)

# Text rules over every file this workload ships.
shipped = {"manifest.toml": mtext, "README.md": rtext}
for fname, text in shipped.items():
    if text is None:
        for what in ("is ASCII", "has no em dash", "uses no banned word", "names no home path",
                     "names no bypass flag in any form", "names no per-directory Claude config"):
            record("%s %s" % (fname, what), False, "file missing")
        continue
    record("%s is ASCII" % fname, all(ord(c) < 128 for c in text), "non-ASCII present")
    record("%s has no em dash" % fname, EM_DASH not in text, "em dash present")
    low = text.lower()
    record("%s uses no banned word" % fname, not [w for w in BANNED if w in low], "banned %r" % [w for w in BANNED if w in low])
    record("%s names no home path" % fname, ("/Use" + "rs/") not in text and "/home/" not in text, "home path present")
    # The README may say what is NOT used; the bypass and per-directory words
    # must not appear in any form, so the README says "no bypass flag" and
    # "no per-directory config" without naming either.
    record("%s names no bypass flag in any form" % fname, not [w for w in BYPASS if w.lower() in low],
           "found %r" % [w for w in BYPASS if w.lower() in low])
    record("%s names no per-directory Claude config" % fname, not [w for w in PER_DIR if w.lower() in low],
           "found %r" % [w for w in PER_DIR if w.lower() in low])
    record("%s carries no token, key or credential value" % fname,
           not re.search(r"(sk-[A-Za-z0-9]{8,}|ghp_[A-Za-z0-9]{8,}|BEGIN [A-Z ]*KEY|nkey|\.creds)", text), "secret-shaped text")

if rtext is not None:
    low = rtext.lower()
    record("README says the rung is optional", "optional" in low, "no 'optional'")
    record("README says it spends quota", "quota" in low, "no 'quota'")
    record("README says it is not part of the release gate", "release gate" in low, "no 'release gate'")
    record("README names the auto mode menu", "teach auto mode" in low and "not now" in low, "no auto mode menu note")
    record("README says plan mode asks about every tool call", "plan mode" in low and "every tool" in low, "no plan mode note")
    record("README tells the human to put the shim on PATH", "director-mcp" in rtext and "path" in low, "no shim note")
    record("README names the launcher form", "--strict-mcp-config" in rtext and "--mcp-config" in rtext, "no launcher note")
    record("README gives the expected lines", "expected" in low and "pong" in low, "no expected lines")
    record("README says it was not run", "not run" in low or "was not run" in low or "has not been run" in low, "no not-run statement")
else:
    for what in ("optional", "quota", "release gate", "auto mode menu", "plan mode note", "shim PATH note",
                 "launcher form", "expected lines", "not-run statement"):
        record("README mentions: %s" % what, False, "no README")

# The table in workloads/README.md gains a fourth, optional row.
if ttext is None:
    record("workloads/README.md lists relay-claude", False, "no workloads/README.md")
else:
    rows = [l for l in ttext.splitlines() if l.startswith("| `relay-claude/`")]
    record("workloads/README.md lists relay-claude", len(rows) == 1, "rows %r" % rows)
    row = rows[0].lower() if rows else ""
    record("the row says optional and spends quota", "optional" in row and "quota" in row, "row %r" % row)
    record("the table still lists the three earlier workloads",
           all(("| `%s/`" % n) in ttext for n in ("ticker", "cron-note", "relay")), "earlier rows missing")

print("\n%d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
