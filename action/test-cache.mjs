import { spawnSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import { join } from "node:path";

// The test-cache step: keys the test targets build-for-testing produced, asks Warmbuild which
// passed before, and hands test-without-building the arguments that leave those out. Any failure
// runs every test the workflow would have run.

const client = join(import.meta.dirname, "client", "warmbuild.mjs");
const input = (name) => (process.env[`INPUT_${name}`] ?? "").trim();
const append = (file, line) => {
  try {
    appendFileSync(process.env[file], `${line}\n`);
  } catch {}
};
const output = (name, value) => append("GITHUB_OUTPUT", `${name}=${value}`);

const args = [input("ARGS"), process.env.WARMBUILD_ONLY_TESTING ?? ""].filter(Boolean).join(" ").replace(/\s+/g, " ").trim();
const everything = (why) => {
  console.log(`::warning title=Warmbuild::test cache unavailable (${why}); every test runs`);
  output("tests", "all");
  output("only-testing", args);
  append("GITHUB_ENV", `WARMBUILD_ONLY_TESTING=${args}`);
  process.exit(0);
};
process.on("uncaughtException", (e) => everything(e?.message ?? String(e)));

const plan = join(process.env.RUNNER_TEMP ?? "/tmp", "warmbuild", "test-cache.json");
const r = spawnSync(
  process.execPath,
  [
    client,
    "test-cache",
    "plan",
    ...(input("DERIVED_DATA") ? ["--derived-data", input("DERIVED_DATA")] : []),
    ...(input("XCTESTRUN") ? ["--xctestrun", input("XCTESTRUN")] : []),
    "--destination",
    input("DESTINATION"),
    "--args",
    args,
    ...(input("WORKSPACE") ? ["--workspace", input("WORKSPACE")] : []),
    "--extra-key",
    input("EXTRA_KEY"),
    ...(input("CACHE_TESTS") === "false" ? ["--off"] : []),
    ...(input("URL") ? ["--url", input("URL")] : []),
    "--out",
    plan,
    ...(process.env.GITHUB_STEP_SUMMARY ? ["--summary", process.env.GITHUB_STEP_SUMMARY] : []),
  ],
  { encoding: "utf8", timeout: 300_000, maxBuffer: 64 * 1024 * 1024 },
);
if (r.stderr?.trim()) console.log(r.stderr.trim());
let p;
try {
  p = JSON.parse(r.stdout.trim().split("\n").pop());
} catch {
  everything(`exit ${r.status ?? r.signal}`);
}
const only = p.args.join(" ");
append("GITHUB_ENV", `WARMBUILD_TEST_CACHE=${plan}`);
append("GITHUB_ENV", `WARMBUILD_ONLY_TESTING=${only}`);
output("tests", p.tests);
output("only-testing", only);
console.log(`Warmbuild: tests ${p.tests}${only ? `: ${only}` : ""}`);
