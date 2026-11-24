import gzip, json, re, collections, datetime as dt
def t(s): return dt.datetime.fromisoformat(s.replace("Z","+00:00")) if s else None
cats = [
 ("setup-runner", r"set up job|complete job|post |^post"),
 ("checkout", r"checkout|submodule"),
 ("xcode-select", r"xcode|select|setup-xcode|xcodes"),
 ("cache-restore", r"cache|restore"),
 ("deps", r"pod|carthage|resolve|dependenc|spm|package|bundle install|brew|mint|tuist (install|fetch)|gem|npm|yarn|install"),
 ("test", r"test|xctest|ui ?test|snapshot"),
 ("build", r"build|compile|archive|xcodebuild|make|tuist"),
 ("lint", r"lint|format|swiftformat|danger|periphery"),
 ("simulator", r"simulator|simctl|boot"),
 ("upload", r"upload|artifact|codecov|coverage|report|publish|deploy|notar|sign"),
]
def cat(name):
    n = name.lower()
    for c, rx in cats:
        if re.search(rx, n): return c
    return "other"
tot = collections.Counter(); jobs = 0; jobsec = 0
per_repo = collections.defaultdict(float)
fail = collections.Counter(); reruns = 0; runs = set(); attempts = collections.Counter()
failstep = collections.Counter()
for line in gzip.open("steps.jsonl.gz", "rt"):
    j = json.loads(line)
    if not j["started"] or not j["completed"]: continue
    d = (t(j["completed"]) - t(j["started"])).total_seconds()
    if d <= 0 or d > 6*3600: continue
    jobs += 1; jobsec += d; per_repo[j["repo"]] += d
    runs.add((j["repo"], j["run"])); attempts[(j["repo"], j["run"])] = max(attempts[(j["repo"], j["run"])], j["attempt"])
    fail[j["jobConclusion"]] += 1
    for s in j["steps"]:
        if not s["started"] or not s["completed"]: continue
        sd = (t(s["completed"]) - t(s["started"])).total_seconds()
        if sd < 0: continue
        c = cat(s["name"]); tot[c] += sd
        if s["conclusion"] == "failure": failstep[c] += 1
print(f"repos {len(per_repo)} runs {len(runs)} macOS jobs {jobs} total {jobsec/3600:.0f} h, median-ish job {jobsec/jobs/60:.1f} min")
s = sum(tot.values())
for c, v in tot.most_common(): print(f"  {c:14s} {v/3600:7.1f} h  {100*v/s:5.1f}%")
print("job conclusions", dict(fail))
print("runs with re-attempts", sum(1 for v in attempts.values() if v > 1), "of", len(attempts))
print("failing step category", dict(failstep.most_common()))
