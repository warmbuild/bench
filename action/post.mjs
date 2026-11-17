import { spawnSync } from "node:child_process";
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

// The cache never fails a job, not even on the way out.
process.on("uncaughtException", (e) => {
  console.log(`Warmbuild: ${e?.message ?? e}`);
  process.exit(0);
});

const client = join(import.meta.dirname, "client", "warmbuild.mjs");
const state = (name) => process.env[`STATE_${name}`] ?? "";
const pid = state("pid");
if (!pid) process.exit(0);

// Waits for the uploads, then the server reports the build.
spawnSync(process.execPath, [client, "stop", "--pid", pid], { stdio: "inherit", timeout: 170_000 });

const log = state("log");
const stats = state("stats");
let s;
try {
  s = JSON.parse(readFileSync(stats, "utf8"));
} catch {
  console.log("Warmbuild: no counters were written");
}

const mb = (n) => `${(n / 1e6).toFixed(1)} MB`;
if (s) {
  const hits = s.kvLocalHits + s.kvRemoteHits + s.kvBundleHits;
  const line = `hits ${hits}, misses ${s.kvMisses}, down ${mb(s.bytesDown)}, up ${mb(s.bytesUp)}, requests ${s.httpRequests}, lost writes ${s.lostWrites}`;
  console.log(`Warmbuild: ${line}`);
  console.log(JSON.stringify(s));
  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(
      process.env.GITHUB_STEP_SUMMARY,
      [
        "### Warmbuild",
        "",
        "| Hits | Misses | Downloaded | Uploaded | HTTP requests | Lost writes |",
        "| ---: | ---: | ---: | ---: | ---: | ---: |",
        `| ${hits} | ${s.kvMisses} | ${mb(s.bytesDown)} | ${mb(s.bytesUp)} | ${s.httpRequests} | ${s.lostWrites} |`,
        "",
      ].join("\n"),
    );
  }
}
// Where the job's time went, from the logs and result bundles Xcode wrote since the main step.
if (state("report") !== "false") {
  const budget = String(Number(state("report-budget")) >= 0 ? Number(state("report-budget")) : 90);
  spawnSync(
    process.execPath,
    [
      client,
      "ci-report",
      "--since",
      state("started") || "0",
      "--workspace",
      state("workspace") || process.cwd(),
      ...(state("url") ? ["--url", state("url")] : []),
      ...(stats ? ["--stats", stats] : []),
      ...(process.env.GITHUB_STEP_SUMMARY ? ["--summary", process.env.GITHUB_STEP_SUMMARY] : []),
      "--upload",
      "--budget",
      budget,
    ],
    { stdio: "inherit", timeout: (Number(budget) + 60) * 1000 },
  );
}

if (log && existsSync(log)) {
  const errors = readFileSync(log, "utf8").split("\n").filter((l) => /\b(ERROR|WARN)\b/.test(l)).slice(-5);
  for (const l of errors) console.log(`Warmbuild log: ${l}`);
}
