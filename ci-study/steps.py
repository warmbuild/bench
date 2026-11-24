# Collects step timings of recent macOS CI runs of the repos in swift.txt into steps.jsonl.
import json, subprocess, sys, os
here = os.path.dirname(os.path.abspath(__file__))
def api(path):
    r = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    try: return json.loads(r.stdout)
    except Exception: return {}
hits = {}
for line in open(os.path.join(here, "hits.txt")):
    repo, path = line.split()
    hits.setdefault(repo, []).append(os.path.basename(path))
out = open(os.path.join(here, "steps.jsonl"), "w")
for repo in [l.strip() for l in open(os.path.join(here, "swift.txt")) if l.strip()]:
    for wf in hits.get(repo, []):
        runs = api(f"repos/{repo}/actions/workflows/{wf}/runs?per_page=15&status=completed").get("workflow_runs", [])
        for run in runs:
            jobs = api(f"repos/{repo}/actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs").get("jobs", [])
            for job in jobs:
                labels = " ".join(job.get("labels") or []).lower()
                if "macos" not in labels and "xcode" not in labels: continue
                out.write(json.dumps({"repo": repo, "wf": wf, "run": run["id"], "attempt": run["run_attempt"],
                    "event": run["event"], "branch": run["head_branch"], "conclusion": run["conclusion"],
                    "created": run["created_at"], "job": job["name"], "jobConclusion": job["conclusion"],
                    "labels": labels, "started": job["started_at"], "completed": job["completed_at"],
                    "steps": [{"name": s["name"], "conclusion": s["conclusion"], "started": s.get("started_at"),
                               "completed": s.get("completed_at")} for s in job.get("steps", [])]}) + "\n")
        out.flush()
    print(repo, file=sys.stderr)
