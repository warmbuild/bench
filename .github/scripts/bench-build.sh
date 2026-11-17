#!/usr/bin/env bash
# One measured build of an external repository for the bench workflow: runs $BUILD in the checkout,
# then writes the time, Xcode's cache hits and misses, and the misses per task type to the job
# summary and to <out dir>/<phase>.json.
#   bench-build.sh <phase> <checkout dir> <out dir>
# $BUILD must write to $DERIVED_DATA and may write its result bundle to $RESULT_BUNDLE.
set -uo pipefail
phase="$1"
checkout="$2"
out="$3"
log="$out/$phase.log"
mkdir -p "$out"
export RESULT_BUNDLE="$out/$phase.xcresult"
rm -rf "$RESULT_BUNDLE"

# A compile flag that differs per run, so the first build of a run finds nothing in the remote
# cache; the other builds of the run share it.
salt=""
if [ -n "${BENCH_SALT:-}" ]; then
  salt=" SWIFT_ACTIVE_COMPILATION_CONDITIONS='\$(inherited) BENCH_$BENCH_SALT'"
  salt="$salt GCC_PREPROCESSOR_DEFINITIONS='\$(inherited) BENCH_SALT=$BENCH_SALT'"
fi

start=$SECONDS
(cd "$checkout" && bash -euo pipefail -c "$BUILD$salt") > "$log" 2>&1
status=$?
seconds=$((SECONDS - start))

hits=$(grep -c '^Cache hit' "$log" || true)
misses=$(grep -c '^Cache miss' "$log" || true)
# A task's first line names its type (CompileC, SwiftCompile, …); its cache line follows.
awk '
  /^Cache hit/ { hit[type]++; next }
  /^Cache miss/ { miss[type]++; next }
  /^[A-Z][A-Za-z]+ / { type = $1 }
  END {
    for (name in miss) print miss[name], name
    for (name in hit) if (!(name in miss)) print 0, name
  }
' "$log" | sort -rn > "$out/$phase-misses.txt"

echo "$phase: exit $status, ${seconds}s, Xcode cache hits $hits, misses $misses"
[ "$status" -eq 0 ] || grep -E 'error:|\*\* BUILD FAILED' "$log" | sort -u | head -n 30
[ "$status" -eq 0 ] || tail -n 40 "$log"

printf '{"phase":"%s","exit":%d,"seconds":%d,"hits":%d,"misses":%d}\n' \
  "$phase" "$status" "$seconds" "$hits" "$misses" > "$out/$phase.json"
{
  echo "### $BENCH_NAME: $phase build"
  echo
  echo "| Exit | Time | Xcode cache hits | Xcode cache misses |"
  echo "| ---: | ---: | ---: | ---: |"
  echo "| $status | ${seconds}s | $hits | $misses |"
  echo
  echo "Misses per task type:"
  echo
  echo '```'
  head -n 15 "$out/$phase-misses.txt"
  echo '```'
  echo
} >> "$GITHUB_STEP_SUMMARY"
exit "$status"
