import { spawnSync } from "node:child_process";
import { appendFileSync, closeSync, mkdirSync, openSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const here = import.meta.dirname;
const client = join(here, "client", "warmbuild.mjs");
const temp = process.env.RUNNER_TEMP ?? "/tmp";
const home = join(temp, "warmbuild");
const paths = {
  // Unix socket paths are limited to about 100 bytes.
  socket: home.length < 80 ? join(home, "warmbuild.sock") : `/tmp/warmbuild-${process.pid}.sock`,
  dir: join(home, "store"),
  cas: join(home, "cas"),
  pid: join(home, "warmbuild.pid"),
  log: join(home, "warmbuild.log"),
  stats: join(home, "stats.json"),
  xcconfig: join(home, "warmbuild.xcconfig"),
};

const input = (name) => (process.env[`INPUT_${name.toUpperCase()}`] ?? "").trim();
const append = (file, line) => {
  try {
    appendFileSync(process.env[file], `${line}\n`);
  } catch {}
};
const output = (name, value) => append("GITHUB_OUTPUT", `${name}=${value}`);
const state = (name, value) => append("GITHUB_STATE", `${name}=${value}`);

// Any failure here leaves the build as it was: no settings, a warning, exit 0.
const disable = (why) => {
  console.log(`::warning title=Warmbuild::${why}; building without the cache`);
  output("enabled", "false");
  process.exit(0);
};
process.on("uncaughtException", (e) => disable(`setup failed: ${e?.message ?? e}`));

mkdirSync(home, { recursive: true });
state("started", String(Date.now()));
state("url", input("url"));
state("workspace", input("workspace") || process.env.GITHUB_WORKSPACE || process.cwd());
state("report", input("report") || "true");
state("report-budget", input("report-budget") || "90");

// Test selection, on pull requests only: the default branch runs everything and catches what a
// pull request skipped. Any failure here runs every test.
function selectTests() {
  if (input("select-tests") !== "true") return;
  try {
    trySelectTests();
  } catch (e) {
    console.log(`::warning title=Warmbuild::test selection failed (${e?.message ?? e}); every test runs`);
    output("tests", "all");
  }
}

function trySelectTests() {
  const pullRequest = /^pull_request/.test(process.env.GITHUB_EVENT_NAME ?? "");
  const everything = (why) => {
    console.log(`Warmbuild: every test runs (${why})`);
    output("tests", "all");
    output("only-testing", "");
    output("swift-filter", "");
    append("GITHUB_ENV", "WARMBUILD_ONLY_TESTING=");
  };
  if (!pullRequest) return everything("not a pull request");
  const lines = (name) => input(name).split("\n").map((l) => l.trim()).filter(Boolean);
  const selectionFile = join(home, "selection.json");
  const r = spawnSync(
    process.execPath,
    [
      client,
      "tests",
      "--repo",
      input("workspace") || process.env.GITHUB_WORKSPACE || process.cwd(),
      "--format",
      "json",
      "--out",
      selectionFile,
      ...(input("url") ? ["--url", input("url")] : []),
      "--sample",
      input("select-tests-sample") || "0.05",
      ...lines("select-tests-ignore").flatMap((r) => ["--ignore", r]),
      ...lines("select-tests-always").flatMap((a) => ["--always", a]),
      ...(input("select-tests-scheme") ? ["--scheme", input("select-tests-scheme")] : []),
      ...(process.env.GITHUB_STEP_SUMMARY ? ["--summary", process.env.GITHUB_STEP_SUMMARY] : []),
    ],
    { encoding: "utf8", env, timeout: 120_000, maxBuffer: 64 * 1024 * 1024 },
  );
  if (r.stderr?.trim()) console.log(r.stderr.trim());
  let s;
  try {
    s = JSON.parse(r.stdout);
  } catch {
    return everything(`selection failed${r.status ? ` (exit ${r.status})` : ""}`);
  }
  append("GITHUB_ENV", `WARMBUILD_SELECTION=${selectionFile}`);
  if (s.all) return everything(s.reason);
  const args = s.xcodebuild.join(" ");
  output("tests", s.xcodebuildTests ?? (s.ids.length ? "some" : "none"));
  output("only-testing", args);
  output("swift-filter", s.swiftFilter ?? "");
  append("GITHUB_ENV", `WARMBUILD_ONLY_TESTING=${args}`);
}

const token = input("token");
if (token) console.log(`::add-mask::${token}`);
const env = { ...process.env, ...(token ? { WARMBUILD_TOKEN: token } : {}) };
const common = ["--socket", paths.socket];
selectTests();

const out = openSync(paths.log, "a");
const start = spawnSync(
  process.execPath,
  [client, "start", ...common, "--dir", paths.dir, "--url", input("url"), "--stats", paths.stats, "--pid", paths.pid, "--log", paths.log],
  { env, stdio: ["ignore", out, out], timeout: 60_000 },
);
closeSync(out);
state("pid", paths.pid);
state("stats", paths.stats);
state("log", paths.log);
if (start.status !== 0) {
  spawnSync(process.execPath, [client, "stop", "--pid", paths.pid], { stdio: "ignore", timeout: 30_000 });
  disable(`the cache server did not start (see ${paths.log})`);
}

const flags = spawnSync(process.execPath, [client, "flags", ...common, "--cas-path", paths.cas, "--workspace", input("workspace") || process.env.GITHUB_WORKSPACE || process.cwd(), "--link"], {
  encoding: "utf8",
});
if (flags.status !== 0) disable("could not compute the xcodebuild settings");
if (flags.stderr.trim()) console.log(`::warning title=Warmbuild::${flags.stderr.trim()}`);

const previous = process.env.XCODE_XCCONFIG_FILE;

// Pull requests only: the compiler's type-check timers in the targets the pull request changes
// (`warmbuild typecheck plan` says why only there). Any failure leaves the settings as they were.
function typecheckLines() {
  if (!/^pull_request/.test(process.env.GITHUB_EVENT_NAME ?? "") || input("typecheck") === "false") return [];
  try {
    const planFile = join(home, "typecheck.json");
    const r = spawnSync(
      process.execPath,
      [
        client,
        "typecheck",
        "plan",
        "--repo",
        input("workspace") || process.env.GITHUB_WORKSPACE || process.cwd(),
        "--out",
        planFile,
        "--threshold",
        input("typecheck-threshold") || "100",
        "--warn",
        input("typecheck-warn") || "1000",
        "--max-files",
        input("typecheck-max-files") || "60",
        ...(previous ? ["--previous-xcconfig", previous] : []),
      ],
      { encoding: "utf8", env, timeout: 60_000, maxBuffer: 16 * 1024 * 1024 },
    );
    if (r.stderr?.trim()) console.log(r.stderr.trim());
    if (r.status !== 0) return [];
    append("GITHUB_ENV", `WARMBUILD_TYPECHECK=${planFile}`);
    return r.stdout.split("\n").filter((l) => l.trim());
  } catch (e) {
    console.log(`Warmbuild: type-check timing off (${e?.message ?? e})`);
    return [];
  }
}
const lines = flags.stdout
  .split("\n")
  .filter(Boolean)
  .map((setting) => {
    const at = setting.indexOf("=");
    return `${setting.slice(0, at)} = ${setting.slice(at + 1)}`;
  });
writeFileSync(paths.xcconfig, [...(previous ? [`#include "${previous}"`] : []), ...lines, ...typecheckLines(), ""].join("\n"));

append("GITHUB_ENV", `XCODE_XCCONFIG_FILE=${paths.xcconfig}`);
output("enabled", "true");
output("xcconfig", paths.xcconfig);
output("stats", paths.stats);
console.log(`Warmbuild: cache server on ${paths.socket}; xcodebuild picks it up through XCODE_XCCONFIG_FILE`);
