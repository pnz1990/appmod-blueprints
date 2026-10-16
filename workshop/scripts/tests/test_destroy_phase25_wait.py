"""Hermetic tests for `task destroy` Phase 2.5 (workshop/Taskfile.yaml): after deleting the
Crossplane DevLake database claim, wait only for what that claim composed, and never abort
`destroy` on a kubectl error.

The Phase 2.5 cmd is read verbatim from the Taskfile and run under go-task (bash with
`set -euo pipefail` if go-task is not on PATH), with a fake `kubectl` and a `sleep` that
only counts. The fake hub always has the AMG workspace's security group, a Crossplane
managed resource that the kro Grafana RGD creates without a claim, as on every workshop
hub with the observability AMG. No cluster, no network.

Run:  python -m pytest workshop/scripts/tests/test_destroy_phase25_wait.py -q
"""
import os
import shutil
import subprocess

import pytest

yaml = pytest.importorskip("yaml")

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
TASKFILE = os.path.join(REPO, "workshop", "Taskfile.yaml")
TASK = shutil.which("task")
if not TASK and not shutil.which("bash"):
    pytest.skip("needs go-task or bash", allow_module_level=True)

# PHASE25_MODE: amg = only the AMG SG; claim = the AMG SG plus a DevLake claim's composed
# SG, which Crossplane deletes after $CLAIM_POLLS polls; down = the hub API is gone.
FAKE_KUBECTL = r"""#!/usr/bin/env bash
echo "kubectl $*" >> "$FAKE_LOG"
if [ "$PHASE25_MODE" = down ]; then
  echo "Unable to connect to the server: dial tcp: lookup hub: no such host" >&2; exit 1
fi
case "$1" in
  delete) echo "No resources found"; exit 0 ;;
  get) ;;
  *) exit 0 ;;
esac
labelled=false
case " $* " in *" -l crossplane.io/claim-name "*|*" --selector crossplane.io/claim-name "*) labelled=true ;; esac
$labelled || echo "crossplane-system   securitygroup.ec2.aws.upbound.io/peeks-amg-sg   True   True   sg-amg   6d"
if [ "$PHASE25_MODE" = claim ]; then
  n=$(cat "$POLLS" 2>/dev/null || echo 0); echo $((n + 1)) > "$POLLS"
  if [ "$n" -lt "$CLAIM_POLLS" ]; then
    echo "crossplane-system   securitygroup.ec2.aws.upbound.io/devlake-mysql-x7k2p-sg   True   True   sg-rds   6d"
  fi
fi
exit 0
"""
FAKE_SLEEP = '#!/usr/bin/env bash\necho "sleep $*" >> "$FAKE_LOG"\n'
VARS = {"HUB_KUBECONFIG": "/nonexistent/hub-kubeconfig",
        "C_STEP": "", "C_OK": "", "C_INFO": "", "C_ERR": "", "C_RESET": ""}


def phase25_cmd():
    cmds = yaml.safe_load(open(TASKFILE))["tasks"]["destroy"]["cmds"]
    hits = [c for c in cmds if isinstance(c, str) and "Phase 2.5" in c]
    assert len(hits) == 1, "expected one Phase 2.5 cmd in workshop destroy"
    return hits[0]


def run(tmp_path, mode, claim_polls=0):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for name, text in (("kubectl", FAKE_KUBECTL), ("sleep", FAKE_SLEEP)):
        (bindir / name).write_text(text)
        (bindir / name).chmod(0o755)
    log = tmp_path / "calls.log"
    env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}", FAKE_LOG=str(log),
               PHASE25_MODE=mode, CLAIM_POLLS=str(claim_polls), POLLS=str(tmp_path / "polls"))
    cmd = phase25_cmd() + "echo PHASE25-DONE\n"
    if TASK:
        taskfile = {"version": "3", "set": ["errexit", "nounset", "pipefail"], "vars": VARS,
                    "tasks": {"phase25": {"cmds": [cmd]}}}
        (tmp_path / "Taskfile.yml").write_text(yaml.safe_dump(taskfile, sort_keys=False))
        argv = [TASK, "-s", "phase25"]
    else:
        for k, v in VARS.items():
            cmd = cmd.replace("{{." + k + "}}", v)
        assert "{{" not in cmd
        (tmp_path / "phase25.sh").write_text("set -euo pipefail\n" + cmd)
        argv = ["bash", str(tmp_path / "phase25.sh")]
    res = subprocess.run(argv, cwd=tmp_path, env=env, capture_output=True, text=True, timeout=120)
    calls = log.read_text().splitlines() if log.exists() else []
    return res, [c for c in calls if c.startswith("sleep")]


def test_no_wait_when_only_unrelated_crossplane_resources_exist(tmp_path):
    """No DevLake claim (DevLake is on ACK): the AMG SG must not hold Phase 2.5 for 15 min."""
    res, sleeps = run(tmp_path, "amg")
    assert res.returncode == 0, res.stdout + res.stderr
    assert "Crossplane RDS managed resources reaped" in res.stdout, res.stdout[-400:]
    assert sleeps == [], f"waited {len(sleeps)} x 10 s for resources Phase 2.5 never deleted"


def test_waits_for_the_claims_composed_resources_only(tmp_path):
    res, sleeps = run(tmp_path, "claim", claim_polls=3)
    assert res.returncode == 0, res.stdout + res.stderr
    assert len(sleeps) == 3, res.stdout[-400:]
    assert "[3/90] waiting for 1 Crossplane RDS managed resource(s)" in res.stdout
    assert "Crossplane RDS managed resources reaped" in res.stdout


def test_kubectl_error_does_not_abort_destroy(tmp_path):
    """Hub already gone (a re-run of destroy): Phase 2.5 must fall through to Phase 3."""
    res, _ = run(tmp_path, "down")
    assert res.returncode == 0, res.stdout + res.stderr
    assert "PHASE25-DONE" in res.stdout
