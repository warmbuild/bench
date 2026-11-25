#!/usr/bin/env bash
# The steps of one tests-bench job (.github/workflows/tests-bench-job.yml), each timed into
# $BENCH_OUT/<phase>.json. The entry of .github/tests-bench/scenarios.json is in $ENTRY.
#   tests-bench.sh skips             writes $SKIP_ARGS: the project's own CI -skip-testing list
#   tests-bench.sh clock-start       the measured part starts (before the Warmbuild step)
#   tests-bench.sh select <base>     test selection for the head commit, as the Action runs it
#   tests-bench.sh phases            the warm job's test phases, one after another (see phase())
#   tests-bench.sh test              one `xcodebuild test` (build and test in one invocation)
#   tests-bench.sh build             `xcodebuild build-for-testing`
#   tests-bench.sh run-tests         `xcodebuild test-without-building $WARMBUILD_ONLY_TESTING`
#   tests-bench.sh package           the entry's package tests, without the step cache
#   tests-bench.sh mark <phase> start|stop   times a step that is not this script's
#   tests-bench.sh clock-stop        writes total.json: the measured part and its phases
#   tests-bench.sh results <phase>   pass/fail/skip counts of a phase's result bundle
#   tests-bench.sh mutate            applies the entry's mutations to the checkout
#   tests-bench.sh verify            failed tests of the mutated run against the selection
set -euo pipefail
out="${BENCH_OUT:?}"
src="${SRC:?}"
mkdir -p "$out"

field() { jq -r "$1 // empty" <<< "${ENTRY:?}"; }

# A compile flag unique to the run and entry, so each fills the cache itself; it changes no product.
salt_settings() {
  printf "%s" "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) BENCH_${BENCH_SALT//-/_}"
}

# Sets COMMON: the arguments every xcodebuild invocation of the entry takes.
common_args() {
  COMMON=(-project "$(field .project)" -scheme "$(field .scheme)"
    -destination 'platform=macOS' -derivedDataPath "${DERIVED_DATA:?}")
}

# Runs a command in the checkout, logs every line with the seconds since it began, and writes
# <phase>.json with the time and the exit status.
timed() {
  local phase="$1"
  shift
  local stamp='BEGIN { $| = 1; $began = time } printf "%7.1f %s", time - $began, $_'
  local start=$SECONDS status
  set +e
  (cd "$src" && "$@") 2>&1 | perl -MTime::HiRes=time -ne "$stamp" > "$out/$phase.log"
  status=${PIPESTATUS[0]}
  set -e
  local seconds=$((SECONDS - start))
  printf '{"phase":"%s","exit":%d,"seconds":%d}\n' "$phase" "$status" "$seconds" \
    > "$out/$phase.json"
  echo "$phase: exit $status, ${seconds} s"
  [ "$status" -eq 0 ] || grep -E 'error:|\*\* (TEST|BUILD) .*FAILED|failed on|✘' "$out/$phase.log" \
    | sort -u | head -n 40 || true
  return 0
}

skips() {
  local name ids=()
  name=$(field .skipFromCi)
  if [ -n "$name" ]; then
    # The list under `<name>: |` in the project's ci.yml, one identifier per line.
    while IFS= read -r id; do ids+=("$id"); done < <(awk -v key="$name:" '
      $1 == key { inside = 1; next }
      inside && /^ *[A-Za-z0-9_]+\// { print $1; next }
      inside && /^ *#/ { next }
      inside { exit }
    ' "$src/.github/workflows/ci.yml")
  fi
  while IFS= read -r id; do [ -z "$id" ] || ids+=("$id"); done < <(field '.skipExtra[]')
  # Tests that fail on this runner image with or without Warmbuild; left out with the fixed Action,
  # whose test-result cache records a target only when every test it runs passes.
  if [ "${ACTION_KIND:-}" = fixed ]; then
    while IFS= read -r id; do [ -z "$id" ] || ids+=("$id"); done < <(field '.skipFailing[]')
  fi
  local args=""
  for id in "${ids[@]+"${ids[@]}"}"; do args="$args -skip-testing:$id"; done
  echo "SKIP_ARGS=${args# }" >> "$GITHUB_ENV"
  echo "${#ids[@]} skipped test identifiers"
}

clock_start() {
  date +%s > "$out/clock-start"
}

# What the Action's main step runs with select-tests: true on a pull request, with the base given
# instead of read from the merge commit (the job runs on workflow_dispatch).
select_tests() {
  local base="$1" start=$SECONDS file="$out/selection.json"
  # stdout has what the Action reads (the xcodebuild arguments); --out only the record.
  node "${WARMBUILD_CLIENT:?}" tests --repo "$src" --base "$base" --format json \
    --url "${CACHE_URL:?}" --sample "${SELECT_SAMPLE:-0.05}" --scheme "$(field .scheme)" \
    ${SELECT_FLAGS:-} \
    --summary "$GITHUB_STEP_SUMMARY" > "$file"
  jq -r 'if .all or .xcodebuildTests == "all" then "" else .xcodebuild | join(" ") end' \
    "$file" > "$out/select-args.txt"
  jq -c '{all, reason, xcodebuildTests, xcodebuildReason, selectedTests, totalTests,
    suites: (.ids | length)}' "$file"
  printf '{"phase":"select","exit":0,"seconds":%d}\n' $((SECONDS - start)) > "$out/select.json"
}

# Selection as fixed in warmbuild#<fix>: a selected target the project declares but the scheme
# does not hold is dropped instead of running everything. Emulated from the published client's
# own output (ids and the scheme's targets), so only that one decision differs.
select_fixed() {
  local file="$out/selection.json"
  jq -r '
    if .all then ""
    else (.schemeTargets // []) as $scheme
      | [.ids[] | select((split("/")[0]) as $t | $scheme | index($t))] as $ids
      | if ($ids | length) == 0 then ($scheme | map("-skip-testing:" + .) | join(" "))
        else ($ids | map("-only-testing:" + .) | join(" ")) end
    end' "$file" > "$out/selectfix-args.txt"
  echo "fixed selection: $(wc -w < "$out/selectfix-args.txt") arguments"
}

# The test-cache step of the published Action (its action/test-cache.mjs, what
# warmbuild/action/test-cache@v1 runs), for one phase: prints its `tests` output on the first
# line and the arguments for test-without-building on the second.
plan_tests() {
  local selection="$1" outputs environment
  outputs=$(mktemp)
  environment=$(mktemp)
  INPUT_DERIVED_DATA="$DERIVED_DATA" INPUT_DESTINATION=platform=macOS INPUT_ARGS="${SKIP_ARGS:-}" \
    INPUT_WORKSPACE="$src" INPUT_EXTRA_KEY="${BENCH_SALT:?}" INPUT_URL="${CACHE_URL:?}" \
    INPUT_CACHE_TESTS=true INPUT_XCTESTRUN="" WARMBUILD_ONLY_TESTING="$selection" \
    GITHUB_OUTPUT="$outputs" GITHUB_ENV="$environment" \
    node "${WARMBUILD_ACTION:?}/action/test-cache.mjs" >&2
  sed -n 's/^tests=//p' "$outputs" | tail -n 1
  sed -n 's/^only-testing=//p' "$outputs" | tail -n 1
}

# One test phase of the warm job, after one build-for-testing with the compilation cache:
#   all        every test the project's CI runs (the compilation cache alone)
#   cache      the test-cache step first (the test-result cache)
#   select     test selection, then the test-cache step (both)
#   selectfix  `select` with the scheme fix applied to the selection's output
# Its time (selection, plan and tests) goes to phase-<name>.json.
phase() {
  local name="$1" start=$SECONDS tests="all" only="" plan
  case "$name" in
    all) only="${SKIP_ARGS:-}" ;;
    cache | select | selectfix)
      local selection=""
      if [ "$name" != cache ]; then
        select_tests "$BASE"
        selection=$(cat "$out/select-args.txt")
      fi
      if [ "$name" = selectfix ]; then
        select_fixed
        selection=$(cat "$out/selectfix-args.txt")
      fi
      plan=$(plan_tests "$selection")
      tests=$(sed -n 1p <<< "$plan")
      only=$(sed -n 2p <<< "$plan")
      ;;
    *) echo "unknown phase $name" >&2; return 2 ;;
  esac
  echo "$name: tests ${tests:-?}, $(wc -w <<< "$only") arguments"
  [ "$tests" = none ] || WARMBUILD_ONLY_TESTING="$only" run_tests "test-$name"
  printf '{"phase":"phase-%s","exit":0,"seconds":%d,"tests":"%s"}\n' "$name" \
    $((SECONDS - start)) "$tests" > "$out/phase-$name.json"
  # Counted after the phase's clock: reading the result bundle is not part of a CI job's tests.
  [ "$tests" = none ] || results "test-$name" || true
}

# The entry's phases, rotated by $ROTATE so each round starts with another one.
phases() {
  local list=() name
  # The fixed Action holds the scheme fix already: selectfix would repeat select.
  while IFS= read -r name; do
    [ "${ACTION_KIND:-}" = fixed ] && [ "$name" = selectfix ] && continue
    list+=("$name")
  done < <(field '.phases[]')
  local count=${#list[@]} offset=$(( ${ROTATE:-0} % ${#list[@]} )) index
  for ((index = 0; index < count; index++)); do
    phase "${list[$(( (index + offset) % count ))]}"
  done
}

xcodebuild_test() {
  common_args
  # shellcheck disable=SC2086
  timed test xcodebuild test "${COMMON[@]}" $(field .settings) $(field .testSettings) \
    "$(salt_settings)" -resultBundlePath "$out/test.xcresult" ${SKIP_ARGS:-}
}

build() {
  common_args
  # shellcheck disable=SC2086
  timed build xcodebuild build-for-testing "${COMMON[@]}" $(field .settings) "$(salt_settings)"
}

run_tests() {
  local phase="${1:-test}"
  common_args
  # shellcheck disable=SC2086
  timed "$phase" xcodebuild test-without-building "${COMMON[@]}" $(field .settings) \
    $(field .testSettings) -resultBundlePath "$out/$phase.xcresult" ${WARMBUILD_ONLY_TESTING:-}
}

package() {
  local run
  run=$(field .package.run)
  [ -n "$run" ] || return 0
  timed package bash -euo pipefail -c "$run"
}

mark() {
  local phase="$1" what="$2"
  if [ "$what" = start ]; then
    date +%s > "$out/$phase.start"
    return 0
  fi
  local seconds=$(($(date +%s) - $(cat "$out/$phase.start")))
  printf '{"phase":"%s","exit":0,"seconds":%d}\n' "$phase" "$seconds" > "$out/$phase.json"
  echo "$phase: ${seconds} s"
}

clock_stop() {
  local started now phases
  started=$(cat "$out/clock-start")
  now=$(date +%s)
  phases=$(cat "$out"/*.json 2> /dev/null | jq -s -c 'map(select(.phase)) | map({(.phase): .})
    | add // {}')
  jq -n -c --arg role "${ROLE:?}" --arg name "$(field .name)" --arg round "${ROUND:-}" \
    --argjson seconds $((now - started)) --argjson phases "$phases" \
    --arg tests "${TESTS_PLANNED:-}" --arg runner "${RUNNER_NAME:-}" \
    '{name: $name, role: $role, round: $round, seconds: $seconds, tests: $tests,
      runner: $runner, phases: $phases}' | tee "$out/total.json"
  echo "### $(field .name), $ROLE: $((now - started)) s in all" >> "$GITHUB_STEP_SUMMARY"
}

# Counts from the result bundle, after the clock. The test phase's build part, in a single
# `xcodebuild test`, is up to the first line the test run prints.
results() {
  local phase="$1" bundle="$out/$1.xcresult" started
  if [ -d "$bundle" ]; then
    xcrun xcresulttool get test-results summary --path "$bundle" --compact > "$out/$phase-summary.json" \
      || echo '{}' > "$out/$phase-summary.json"
    xcrun xcresulttool get test-results tests --path "$bundle" --compact > "$out/$phase-tests.json" \
      || echo '{}' > "$out/$phase-tests.json"
  else
    echo '{}' > "$out/$phase-summary.json"
  fi
  started=$(grep -m 1 -E "Test Suite '.*' started|Test run started|Testing started" \
    "$out/$phase.log" 2> /dev/null | awk '{ print $1 }' || true)
  jq -c --arg started "${started:-}" '{totalTestCount, passedTests, failedTests, skippedTests,
    expectedFailures, result, testsStartAt: ($started | tonumber? // null)}' \
    "$out/$phase-summary.json" | tee "$out/$phase-results.txt"
  echo "Results of $phase: $(cat "$out/$phase-results.txt")" >> "$GITHUB_STEP_SUMMARY"
}

mutate() {
  jq -c '.mutations[]' <<< "$ENTRY" | while IFS= read -r mutation; do
    MUTATION="$mutation" python3 -I -c '
import json, os, sys
m = json.loads(os.environ["MUTATION"])
path = os.path.join(os.environ["SRC"], m["file"])
text = open(path).read()
count = text.count(m["find"])
if count == 0:
    sys.exit("mutation not found in " + m["file"] + ": " + m["find"])
open(path, "w").write(text.replace(m["find"], m["replace"]))
print("mutated", m["file"], count, "place(s):", m["replace"])
'
  done
}

# Every test that failed with the mutations must be one the selection ran: its target/suite (or
# target/function) is among the selected ids. A failure outside the selection is a miss.
verify() {
  local selection="$out/selection.json" tests="$out/test-tests.json"
  python3 -I - "$selection" "$tests" << 'EOF' | tee "$out/verify.txt"
import json, sys
selection = json.load(open(sys.argv[1]))
tree = json.load(open(sys.argv[2]))
selected = set(selection.get("ids", []))
failed = []
def walk(node, path):
    kind = node.get("nodeType")
    here = path + [node]
    if kind == "Test Case" and node.get("result") == "Failed":
        failed.append(here)
    for child in node.get("children", []):
        walk(child, here)
for node in tree.get("testNodes", []):
    walk(node, [])
def ids_of(path):
    target = next((n["name"] for n in path if n.get("nodeType") == "Unit test bundle"), "?")
    suites = [n["name"] for n in path if n.get("nodeType") == "Test Suite"]
    # A case's identifier is Type/method() in a suite, or function() at the top level; suites in
    # the tree carry display names, so the type comes from the identifier.
    case = path[-1].get("nodeIdentifier") or path[-1]["name"]
    candidates = [f"{target}/{case.split('/')[0]}", f"{target}/{case}"]
    return target, suites, case, candidates
misses = []
for path in failed:
    target, suites, case, candidates = ids_of(path)
    hit = selection.get("all") or any(c in selected for c in candidates)
    if not hit:
        misses.append(f"{target}/{'/'.join(suites)}/{case}")
print(json.dumps({"failed": len(failed), "misses": len(misses), "selectedSuites": len(selected),
                  "selectionAll": selection.get("all"), "missed": misses[:50]}))
EOF
  echo "Mutation check: $(cat "$out/verify.txt")" >> "$GITHUB_STEP_SUMMARY"
}

case "$1" in
  skips) skips ;;
  clock-start) clock_start ;;
  mark) mark "$2" "$3" ;;
  select) select_tests "$2" ;;
  test) xcodebuild_test ;;
  build) build ;;
  run-tests) run_tests test ;;
  phases) phases ;;
  package) package ;;
  clock-stop) clock_stop ;;
  results) results "$2" ;;
  mutate) mutate ;;
  verify) verify ;;
  *) echo "unknown step $1" >&2; exit 2 ;;
esac
