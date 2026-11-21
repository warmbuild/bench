#!/usr/bin/env bash
# The steps of a CI scenario (.github/bench/scenarios.json) for the scenarios workflow, each timed.
#   scenario.sh simulator          finds an iPhone 17 on the newest iOS runtime: $TEST_DESTINATION
#   scenario.sh edit <checkout>    changes the entry's $EDIT file the way a pull request would
#   scenario.sh clock-start        the job's measured part starts (before the Warmbuild step)
#   scenario.sh boot               boots the simulator, timed
#   scenario.sh clock-stop <role>  writes <out>/total.json: the measured part and its phases
# Every step writes into $BENCH_OUT.
set -euo pipefail
out="${BENCH_OUT:?}"
mkdir -p "$out"

# The device Wikipedia's own CI tests on, on the newest runtime the selected Xcode has.
simulator() {
  local devices udid
  devices=$(xcrun simctl list devices available -j)
  udid=$(jq -r '
    def version: capture("iOS-(?<v>[0-9-]+)").v | split("-") | map(select(. != "") | tonumber);
    .devices | to_entries
    | map(select(.key | test("SimRuntime.iOS-")))
    | map({version: (.key | version), device: (.value | map(select(.name == "iPhone 17")))[0]})
    | map(select(.device)) | sort_by(.version) | last | .device.udid // empty
  ' <<< "$devices")
  [ -n "$udid" ] || { xcrun simctl list runtimes; echo "::error::no iPhone 17 simulator"; exit 1; }
  echo "TEST_DESTINATION=platform=iOS Simulator,id=$udid" >> "$GITHUB_ENV"
  echo "SIMULATOR_UDID=$udid" >> "$GITHUB_ENV"
  echo "simulator $udid"
}

# A pull request's change: a new function in one Swift file, which changes that file's compile.
edit() {
  local checkout="$1"
  printf '\nprivate func warmbuildBenchEdit() -> Int { 1 }\n' >> "$checkout/${EDIT:?}"
  echo "edited $EDIT"
}

clock_start() {
  date +%s > "$out/clock-start"
}

boot() {
  local start=$SECONDS
  xcrun simctl boot "${SIMULATOR_UDID:?}" || true
  xcrun simctl bootstatus "$SIMULATOR_UDID" -b
  printf '{"phase":"boot","exit":0,"seconds":%d}\n' $((SECONDS - start)) > "$out/boot.json"
}

# The measured part of the job, from the clock's start (the Warmbuild step included) to now, and
# the phases that ran in it.
clock_stop() {
  local role="$1" started now phases
  started=$(cat "$out/clock-start")
  now=$(date +%s)
  phases=$(cat "$out"/*.json 2> /dev/null | jq -s -c 'map(select(.phase)) | map({(.phase): .})
    | add // {}')
  jq -n -c --arg role "$role" --arg name "${BENCH_NAME:-}" --argjson seconds $((now - started)) \
    --argjson phases "$phases" --arg tests "${TESTS_PLANNED:-}" \
    '{name: $name, role: $role, seconds: $seconds, tests: $tests, phases: $phases}' \
    | tee "$out/total.json"
  {
    echo "### $BENCH_NAME, $role: $((now - started)) s in all"
    echo
  } >> "$GITHUB_STEP_SUMMARY"
}

case "$1" in
  simulator) simulator ;;
  edit) edit "$2" ;;
  clock-start) clock_start ;;
  boot) boot ;;
  clock-stop) clock_stop "$2" ;;
  *) echo "unknown step $1" >&2; exit 2 ;;
esac
