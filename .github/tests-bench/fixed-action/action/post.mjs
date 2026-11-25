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

// SourcePackages for the next fresh runner: once per set of pins, after the build's own uploads.
if (state("packages") !== "false" && state("url")) {
  const token = (process.env.INPUT_TOKEN ?? "").trim();
  const build = (process.env.INPUT_BUILD ?? "").trim();
  const env = {
    ...process.env,
    ...(token ? { WARMBUILD_TOKEN: token } : {}),
    ...(build ? { WARMBUILD_BUILD: build } : {}),
  };
  const workspace = state("workspace") || process.cwd();
  // Without the main step's start time this job's packages cannot be told from older ones: none
  // are saved.
  const since = state("started") || String(Number.MAX_SAFE_INTEGER);
  const save = ["packages", "save", "--url", state("url"), "--workspace", workspace];
  save.push("--since", since);
  spawnSync(process.execPath, [client, ...save], { env, stdio: "inherit", timeout: 180_000 });
}

const log = state("log");
const stats = state("stats");
let s;
try {
  s = JSON.parse(readFileSync(stats, "utf8"));
} catch {
  console.log("Warmbuild: no counters were written");
}

const mb = (n) => `${(n / 1e6).toFixed(1)} MB`;
// The share of Xcode's cache lookups that hit, for the summary's heading; none without lookups.
const hitShare = (hits, misses) => {
  if (hits + misses === 0) return "";
  return ` · ${Math.round((hits / (hits + misses)) * 100)}% of compile tasks from the cache`;
};
if (s) {
  const hits = s.kvLocalHits + s.kvRemoteHits;
  const line = `hits ${hits}, misses ${s.kvMisses}, down ${mb(s.bytesDown)}, up ${mb(s.bytesUp)}, requests ${s.httpRequests}, lost writes ${s.lostWrites}`;
  console.log(`Warmbuild: ${line}`);
  console.log(JSON.stringify(s));
  // A writer refused writes only when the account's storage quota is used up: the build passes,
  // but the next one gets nothing new from it. Said where the job's page shows it.
  if (s.deniedWrites > 0) {
    const why = "the storage quota is used up, so this build's results were not saved";
    console.log(`::warning title=Warmbuild::${why}. See https://warmbuild.dev/app/`);
  }
  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(
      process.env.GITHUB_STEP_SUMMARY,
      [
        `### [Warmbuild](https://warmbuild.dev/)${hitShare(hits, s.kvMisses)}`,
        "",
        "| Hits | Misses | Downloaded | Uploaded | HTTP requests | Lost writes |",
        "| ---: | ---: | ---: | ---: | ---: | ---: |",
        `| ${hits} | ${s.kvMisses} | ${mb(s.bytesDown)} | ${mb(s.bytesUp)} | ${s.httpRequests} | ${s.lostWrites} |`,
        "",
        "History per repository, trends and findings: [dashboard](https://warmbuild.dev/app/).",
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
