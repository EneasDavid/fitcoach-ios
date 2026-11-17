#!/usr/bin/env python3
"""Static checks for the GitHub Actions workflows: the OWASP Top 10 CI/CD Security Risks that can be judged from the YAML alone.

  CICD-SEC-1  insufficient flow control      no `pull_request_target` (untrusted PR code must never run with secrets)
  CICD-SEC-2  inadequate IAM                 every workflow declares least-privilege `permissions`, never `write-all`
  CICD-SEC-3  dependency chain abuse         every action pinned to a full commit SHA (a tag can be repointed; Dependabot updates the SHA)
  CICD-SEC-4  poisoned pipeline execution    no untrusted `${{ ... }}` (PR title, branch name, inputs…) inside `run:` — pass it through `env:`
  CICD-SEC-5  insufficient PBAC              every job has a timeout (a hung or hijacked job cannot run for 6 hours)
  CICD-SEC-6  credential hygiene             `actions/checkout` does not persist the token; secrets are never echoed

Usage: check_workflows.py [workflow files…]   (default: .github/workflows/*.yml)   Exit code 1 when anything is found.
"""
import pathlib
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: pip install pyyaml")

SHA = re.compile(r"^[0-9a-f]{40}$")
UNTRUSTED = re.compile(
    r"\$\{\{\s*(github\.event\.(issue|pull_request|comment|review|review_comment|head_commit|commits|pages|discussion|inputs)\b"
    r"|github\.head_ref|inputs\.)")
ECHOED_SECRET = re.compile(r"echo\s+[^\n]*\$\{\{\s*secrets\.")


def check_workflow(name: str, doc: dict) -> list[str]:
    problems: list[str] = []
    triggers = doc.get(True, doc.get("on", {}))          # YAML 1.1 reads the key `on:` as boolean True
    trigger_names = set(triggers if isinstance(triggers, (dict, list)) else [triggers])
    if "pull_request_target" in trigger_names:
        problems.append(f"{name}: uses pull_request_target (CICD-SEC-1)")

    permissions = doc.get("permissions")
    if permissions is None:
        problems.append(f"{name}: no top-level `permissions:` — the token would default to the repository's broad setting (CICD-SEC-2)")
    elif permissions == "write-all":
        problems.append(f"{name}: permissions: write-all (CICD-SEC-2)")

    for job_id, job in (doc.get("jobs") or {}).items():
        where = f"{name} job `{job_id}`"
        if job.get("uses"):                       # a call to a reusable workflow: GitHub forbids `timeout-minutes` here (the called jobs carry their own)
            problems += _check_uses(where, job["uses"], {})
            continue
        if "timeout-minutes" not in job:
            problems.append(f"{where}: no timeout-minutes (CICD-SEC-5)")
        for index, step in enumerate(job.get("steps") or []):
            label = f"{where} step {index + 1}"
            uses = step.get("uses")
            if uses:
                problems += _check_uses(label, uses, step)
            run = step.get("run")
            if run:
                if UNTRUSTED.search(run):
                    problems.append(f"{label}: untrusted ${{{{ }}}} expression inside `run:` — pass it via `env:` (CICD-SEC-4)")
                if ECHOED_SECRET.search(run):
                    problems.append(f"{label}: echoes a secret (CICD-SEC-6)")
    return problems


def _check_uses(label: str, uses: str, step: dict) -> list[str]:
    if uses.startswith("./"):
        return []
    if uses.startswith("docker://"):
        return [] if "@sha256:" in uses else [f"{label}: docker image `{uses}` is not pinned by digest (CICD-SEC-3)"]
    action, _, ref = uses.partition("@")
    problems = []
    if not ref:
        problems.append(f"{label}: `{uses}` has no version (CICD-SEC-3)")
    elif not SHA.match(ref):
        problems.append(f"{label}: `{uses}` must be pinned to a full 40-character commit SHA, not a tag or branch (CICD-SEC-3)")
    if action.startswith("actions/checkout") and (step.get("with") or {}).get("persist-credentials") is not False:
        problems.append(f"{label}: actions/checkout must set `persist-credentials: false` (CICD-SEC-6)")
    return problems


def main(argv: list[str]) -> int:
    root = pathlib.Path(__file__).resolve().parents[2]
    files = [pathlib.Path(a) for a in argv] or sorted((root / ".github" / "workflows").glob("*.y*ml"))
    problems: list[str] = []
    for path in files:
        try:
            doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        except yaml.YAMLError as error:
            problems.append(f"{path.name}: not valid YAML: {error}")
            continue
        problems += check_workflow(path.name, doc or {})
    for problem in problems:
        print(f"✗ {problem}")
    print(f"{len(files)} workflow(s) checked, {len(problems)} problem(s).")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
