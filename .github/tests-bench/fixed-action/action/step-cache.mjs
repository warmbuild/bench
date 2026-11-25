import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

// The step-cache step: keys a CI step (swift test, a package build) by the files it reads, asks
// Warmbuild whether those inputs passed before, and runs the step's command unless they did. A
// skip is always announced; when the key cannot be computed or Warmbuild cannot answer, the
// command runs. The Action's post step reports a pass, so the next job with these inputs skips.

const client = join(import.meta.dirname, "client", "warmbuild.mjs");
const input = (name) => (process.env[`INPUT_${name}`] ?? "").trim();
const append = (file, line) => {
  try {
    // One line per entry: a newline in a value would start another output.
    appendFileSync(process.env[file], `${String(line).replace(/[\r\n]+/g, " ")}\n`);
  } catch {}
};
const output = (name, value) => append("GITHUB_OUTPUT", `${name}=${value}`);

// Values the workflow writes go as `--flag=value`: as a separate word, a value that starts with
// "-" (every -only-testing / -skip-testing argument) is read as another flag and the command fails.

// What the plan says; null when the client could not plan.
const planned = (stdout) => {
  try {
    return JSON.parse(stdout.trim().split("\n").pop());
  } catch {
    return null;
  }
};

const name = input("NAME");
const command = process.env.INPUT_RUN ?? "";
if (!name || !command.trim()) {
  console.log("::error title=Warmbuild::step-cache needs `name` and `run`");
  process.exit(1);
}

// One plan file per step name, so two cached steps of a job keep their own.
const directory = join(process.env.RUNNER_TEMP ?? "/tmp", "warmbuild", "steps");
const planFile = join(directory, `${createHash("sha256").update(name).digest("hex").slice(0, 16)}.json`);

let decision = null;
try {
  mkdirSync(directory, { recursive: true });
  const r = spawnSync(
    process.execPath,
    [
      client,
      "test-cache",
      "step",
      "plan",
      `--name=${name}`,
      `--command=${command}`,
      ...(input("PACKAGE_PATH") ? ["--package-path", input("PACKAGE_PATH")] : []),
      `--paths=${input("PATHS")}`,
      `--destination=${input("DESTINATION")}`,
      ...(input("WORKSPACE") ? ["--workspace", input("WORKSPACE")] : []),
      `--extra-key=${input("EXTRA_KEY")}`,
      ...(input("CACHE_STEPS") === "false" ? ["--off"] : []),
      ...(input("URL") ? ["--url", input("URL")] : []),
      "--out",
      planFile,
      ...(process.env.GITHUB_STEP_SUMMARY ? ["--summary", process.env.GITHUB_STEP_SUMMARY] : []),
    ],
    { encoding: "utf8", timeout: 300_000, maxBuffer: 64 * 1024 * 1024 },
  );
  if (r.stderr?.trim()) console.log(r.stderr.trim());
  decision = planned(r.stdout ?? "");
  if (!decision) console.log(`::warning title=Warmbuild::step cache unavailable (exit ${r.status ?? r.signal}); ${name} runs`);
} catch (e) {
  console.log(`::warning title=Warmbuild::step cache unavailable (${e?.message ?? e}); ${name} runs`);
}

output("key", decision?.key ?? "");
if (decision?.key) append("GITHUB_ENV", `WARMBUILD_STEP_CACHE=${directory}`);
if (decision && decision.run === false) {
  console.log(`::notice title=Warmbuild::${decision.why}`);
  output("ran", "false");
  process.exit(0);
}

const started = Date.now();
const run = spawnSync("bash", ["--noprofile", "--norc", "-eo", "pipefail", "-c", command], { stdio: "inherit" });
const exitCode = run.status ?? 1;
if (decision?.key) {
  spawnSync(
    process.execPath,
    [client, "test-cache", "step", "record", "--plan", planFile, "--exit-code", String(exitCode), "--duration-ms", String(Date.now() - started)],
    { stdio: "inherit", timeout: 60_000 },
  );
}
output("ran", "true");
process.exit(exitCode);
