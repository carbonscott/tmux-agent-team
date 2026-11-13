"""Check the result yourself: clone main into a fresh directory, run the task's check for every
statement (in the same no-network sandbox the merge job uses), and confirm that nothing
outside the allowed paths changed since the seed. Exit status 0 only if everything holds."""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("gateway", R + "/harness/gateway.py")
gw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gw)

tree = tempfile.mkdtemp(prefix="verify-")
try:
    subprocess.run(["git", "clone", "-q", gw.CENTRAL, tree], check=True, env=gw.GITENV)
    head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=tree, capture_output=True, text=True).stdout.strip()
    print("main is at %s" % head)
    bad = 0
    for s in gw.STATEMENTS:
        ok, out = gw.run_check(tree, s)
        print("%s  %-16s %s" % ("PASS" if ok else "FAIL", s, (out.splitlines() or [""])[-1][:80]))
        bad += 0 if ok else 1
    seed = open(R + "/state/seed_sha").read().strip()
    changed = subprocess.run(["git", "diff", "--name-only", seed, "HEAD"], cwd=tree, capture_output=True, text=True).stdout.split()
    frozen = [p for p in changed if not gw.path_ok(p)]
    print("%s  frozen files      %s" % ("FAIL" if frozen else "PASS", "changed: " + " ".join(frozen) if frozen else "unchanged since the seed"))
    done = len(gw.STATEMENTS) - bad
    print("%d of %d statements pass on a fresh checkout" % (done, len(gw.STATEMENTS)))
    sys.exit(1 if bad or frozen else 0)
finally:
    shutil.rmtree(tree, ignore_errors=True)
