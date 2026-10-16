#!/usr/bin/env bash
#
# Self-test for the test harness itself.
#
# scripts/run-tests.sh and scripts/test-summary.sh are the things that decide
# whether a run is honest, so they need their own regression net: if the gate
# silently stops failing, every future green check is worthless again — which
# is the exact failure this harness was built to end.
#
# It drives both scripts with a stubbed `dotnet` and `docker` (no SDK, no
# container runtime, no network needed), and asserts the outcomes that matter:
#
#   * a failing integration test reddens the run
#   * no Docker means the integration tests are reported as never-run and the
#     gate fails — it never means a quiet green
#   * an assembly that exceeds its never-run budget fails; one within budget
#     passes and says how many did not run
#
# Run it with:  bash scripts/selftest.sh

set -uo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
nope() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/       | /'; }

# --- stubs -----------------------------------------------------------------

mkdir -p "$tmp/bin"

cat > "$tmp/bin/dotnet" <<'STUB'
#!/usr/bin/env bash
# Stub `dotnet`. `dotnet msbuild -getProperty:TargetFramework(s)` answers from
# $STUB_TFMS / $STUB_TFM (default: a net9.0;net10.0 multi-target, as the real
# projects since NET10-01). `dotnet test` reads $STUB_CONFIG, a TSV of
#   assembly  discovered  total  executed  passed  failed  notExecuted  exit
# and applies the assembly's row to whichever target it is run for; it refuses
# to run without one, since an unframed run is the overwrite the harness avoids.
set -uo pipefail
if [ "${1:-}" = "msbuild" ]; then
    for arg in "$@"; do
        case "$arg" in
            -getProperty:TargetFrameworks) printf '%s\n' "${STUB_TFMS-net9.0;net10.0}"; exit 0 ;;
            -getProperty:TargetFramework)  printf '%s\n' "${STUB_TFM-}"; exit 0 ;;
        esac
    done
    echo "stub: unsupported msbuild call: $*" >&2; exit 3
fi
mode="run"; results_dir="."; logger=""; proj=""; tfm=""
while [ $# -gt 0 ]; do
    case "$1" in
        --list-tests)          mode="list"; shift ;;
        --results-directory)   results_dir="$2"; shift 2 ;;
        --logger)              logger="$2"; shift 2 ;;
        -c|--configuration)    shift 2 ;;
        -f|--framework)        tfm="$2"; shift 2 ;;
        *.csproj)              proj="$1"; shift ;;
        *)                     shift ;;
    esac
done
[ -n "$tfm" ] || { echo "stub: dotnet test called without -f <target>" >&2; exit 3; }
assembly=$(basename "$proj" .csproj)
row=$(awk -F'\t' -v a="$assembly" '$1 == a { print; exit }' "$STUB_CONFIG")
[ -n "$row" ] || { echo "stub: no config row for $assembly" >&2; exit 3; }
IFS=$'\t' read -r _ discovered total executed passed failed notexec code <<< "$row"

if [ "$mode" = "list" ]; then
    echo "The following Tests are available:"
    # $STUB_NO_RUNTIME names a target whose runtime is "missing": vstest then
    # prints the marker, an exception, and exits 0 — exactly what a real SDK 10
    # without the .NET 9 runtime does.
    if [ "${STUB_NO_RUNTIME-}" = "$tfm" ]; then
        echo "Microsoft.VisualStudio.TestPlatform.ObjectModel.TestPlatformException: Testhost process for source(s) '$proj' exited with error: You must install or update .NET to run this application."
        echo "Framework: 'Microsoft.NETCore.App', version '9.0.0' (arm64)"
        echo "   at Microsoft.VisualStudio.TestPlatform.CrossPlatEngine.Client.ProxyOperationManager.ThrowOnTestHostExited(...)"
        echo "   at Microsoft.VisualStudio.TestPlatform.CrossPlatEngine.Client.ProxyOperationManager.SetupChannel(...)"
        echo "   at Microsoft.VisualStudio.TestPlatform.CrossPlatEngine.Client.ProxyDiscoveryManager.InitializeDiscovery(...)"
        echo "   at Microsoft.VisualStudio.TestPlatform.CrossPlatEngine.Client.ProxyDiscoveryManager.DiscoverTests(...)"
        exit 0
    fi
    i=1; while [ "$i" -le "$discovered" ]; do echo "    $assembly.Test$i"; i=$((i + 1)); done
    exit 0
fi

logfile="${logger#trx;LogFileName=}"
mkdir -p "$results_dir"
cat > "$results_dir/$logfile" <<TRX
<?xml version="1.0" encoding="UTF-8"?>
<TestRun>
  <ResultSummary outcome="Completed">
    <Counters total="$total" executed="$executed" passed="$passed" failed="$failed" error="0" timeout="0" aborted="0" inconclusive="0" passedButRunAborted="0" notRunnable="0" notExecuted="$notexec" disconnected="0" warning="0" completed="0" inProgress="0" pending="0" />
  </ResultSummary>
</TestRun>
TRX
exit "$code"
STUB

cat > "$tmp/bin/docker" <<'STUB'
#!/usr/bin/env bash
if [ "${STUB_DOCKER_OK:-1}" = "1" ]; then
    echo " Server Version: 99.0.0-stub"
    exit 0
fi
echo "Cannot connect to the Docker daemon. Is the docker daemon running?" >&2
exit 1
STUB

chmod +x "$tmp/bin/dotnet" "$tmp/bin/docker"
export DOTNET="$tmp/bin/dotnet"
export DOCKER="$tmp/bin/docker"

UNIT="Compendium.Adapters.PostgreSQL.Tests"
INTEG="Compendium.Adapters.PostgreSQL.IntegrationTests"

# assembly  discovered  total  executed  passed  failed  notExecuted  exit
write_config() { printf '%s\n' "$@" > "$tmp/config.tsv"; export STUB_CONFIG="$tmp/config.tsv"; }
green_unit="$UNIT	199	199	199	199	0	0	0"

run_tests() {  # run_tests <results-subdir> [extra args...]
    local sub="$1"; shift
    "$repo_root/scripts/run-tests.sh" --results-directory "$tmp/$sub" --no-build "$@" 2>&1
}

echo "run-tests.sh"

# --- a failing integration test must redden the run ------------------------
write_config "$green_unit" "$INTEG	28	28	24	23	1	4	1"
out=$(STUB_DOCKER_OK=1 run_tests r1); rc=$?
if [ "$rc" -ne 0 ]; then ok "a failing integration test fails the run"
else nope "a failing integration test fails the run" "$out"; fi
if printf '%s' "$out" | grep -q "24 / 28"; then ok "the report shows executed / discovered"
else nope "the report shows executed / discovered" "$out"; fi

# --- everything green ------------------------------------------------------
write_config "$green_unit" "$INTEG	28	28	24	24	0	4	0"
out=$(STUB_DOCKER_OK=1 run_tests r2); rc=$?
if [ "$rc" -eq 0 ]; then ok "a fully green run with 4 budgeted skips passes"
else nope "a fully green run with 4 budgeted skips passes" "$out"; fi
if printf '%s' "$out" | grep -q "docker info\` succeeded"; then ok "Docker is established by preflight, not assumed"
else nope "Docker is established by preflight, not assumed" "$out"; fi

# --- NET10-01: one lane per (assembly, target), nothing shared ---------------
# 199 + 28 tests, twice (net9.0 and net10.0): 454 discovered, 446 executed. One
# .trx per target, so the net10.0 run cannot overwrite the net9.0 one.
if [ -f "$tmp/r2/$INTEG.net9.0.trx" ] && [ -f "$tmp/r2/$INTEG.net10.0.trx" ] \
   && [ -f "$tmp/r2/$UNIT.net9.0.trx" ] && [ -f "$tmp/r2/$UNIT.net10.0.trx" ]; then
    ok "every (assembly, target) pair writes its own .trx"
else nope "every (assembly, target) pair writes its own .trx" "$(ls "$tmp/r2")"; fi
if printf '%s' "$out" | grep -q "| \`$INTEG\` · \`net9.0\` | 24 / 28 |" \
   && printf '%s' "$out" | grep -q "| \`$INTEG\` · \`net10.0\` | 24 / 28 |"; then
    ok "the report has one row per target"
else nope "the report has one row per target" "$out"; fi
if printf '%s' "$out" | grep -q "446 / 454"; then ok "totals count each target once: 446 / 454"
else nope "totals count each target once: 446 / 454" "$out"; fi

# --- a single-target project (TargetFramework only) is still one lane --------
write_config "$green_unit" "$INTEG	28	28	24	24	0	4	0"
out=$(STUB_TFMS="" STUB_TFM="net9.0" STUB_DOCKER_OK=1 run_tests r2b); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "223 / 227" && [ -f "$tmp/r2b/$UNIT.net9.0.trx" ]; then
    ok "a project with only TargetFramework runs as a single net9.0 lane"
else nope "a project with only TargetFramework runs as a single net9.0 lane" "$out"; fi

# --- no Docker is never a quiet green --------------------------------------
write_config "$green_unit" "$INTEG	28	28	24	24	0	4	0"
out=$(STUB_DOCKER_OK=0 run_tests r3); rc=$?
if [ "$rc" -ne 0 ]; then ok "no Docker fails the gate instead of passing quietly"
else nope "no Docker fails the gate instead of passing quietly" "$out"; fi
if printf '%s' "$out" | grep -q "28 test(s) never ran"; then ok "no Docker prints how many tests never ran"
else nope "no Docker prints how many tests never ran" "$out"; fi

# --- --require-integration refuses to start without Docker -----------------
out=$(STUB_DOCKER_OK=0 run_tests r4 --require-integration); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "require-integration"; then
    ok "--require-integration refuses to run without Docker"
else nope "--require-integration refuses to run without Docker" "$out"; fi

# --- --skip-integration is honest about what it did not run ----------------
write_config "$green_unit" "$INTEG	28	28	24	24	0	4	0"
out=$(STUB_DOCKER_OK=1 run_tests r5 --skip-integration); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "0 / 28"; then
    ok "--skip-integration reports 0 / 28 and does not go green"
else nope "--skip-integration reports 0 / 28 and does not go green" "$out"; fi

# --- a stale .trx cannot be credited to a lane that did not run ------------
write_config "$green_unit" "$INTEG	28	28	24	24	0	4	0"
STUB_DOCKER_OK=1 run_tests r6 >/dev/null 2>&1 || true
if [ ! -f "$tmp/r6/$INTEG.net9.0.trx" ]; then
    nope "stale .trx: setup failed, no first-run .trx to go stale"
else
    out=$(STUB_DOCKER_OK=0 run_tests r6); rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "0 / 28"; then
        ok "a stale .trx is not credited to a lane that did not run"
    else nope "a stale .trx is not credited to a lane that did not run" "$out"; fi
fi

# --- a vacuous discovery is fatal, not a free pass -------------------------
write_config "$UNIT	0	0	0	0	0	0	0" "$INTEG	0	0	0	0	0	0	0"
out=$(STUB_DOCKER_OK=1 run_tests r7); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "0 tests discovered"; then
    ok "discovering zero tests in a test project is fatal"
else nope "discovering zero tests in a test project is fatal" "$out"; fi

# --- a test host that cannot start is a failed discovery, not a count --------
# Without the .NET 9 runtime, `--list-tests` for net9.0 prints the marker and an
# exception, exits 0, and its four stack frames would pass for four tests.
write_config "$green_unit" "$INTEG	28	28	24	24	0	4	0"
out=$(STUB_NO_RUNTIME=net9.0 STUB_DOCKER_OK=1 run_tests r7b); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "test host could not start (is the net9.0 runtime installed?)"; then
    ok "a test host that cannot start fails discovery instead of counting its stack frames"
else nope "a test host that cannot start fails discovery instead of counting its stack frames" "$out"; fi
if ! printf '%s' "$out" | grep -q -E "\(net9.0\): [0-9]+$"; then
    ok "no net9.0 lane reports a discovery count when its runtime is missing"
else nope "no net9.0 lane reports a discovery count when its runtime is missing" "$out"; fi

echo "test-summary.sh"

summary() {  # summary <dir> <discovered-tsv-content> [budget-content]
    local dir="$tmp/$1"; shift
    mkdir -p "$dir"
    printf '%s\n' "$1" > "$dir/discovered.tsv"; shift
    local budget="$dir/budget.tsv"
    printf '%s\n' "${1:-}" > "$budget"
    "$repo_root/scripts/test-summary.sh" --results-directory "$dir" --budget "$budget" 2>&1
}

trx() {  # trx <dir> <assembly> <total> <executed> <passed> <failed> <notExecuted>
    mkdir -p "$tmp/$1"
    cat > "$tmp/$1/$2.trx" <<TRX
<TestRun><ResultSummary><Counters total="$3" executed="$4" passed="$5" failed="$6" error="0" notRunnable="0" notExecuted="$7" /></ResultSummary></TestRun>
TRX
}

# an assembly whose tests were filtered out entirely: no .trx at all
out=$(summary s1 "$INTEG	28" ""); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "0 / 28"; then
    ok "an assembly that never ran reports 0 / 28 and fails"
else nope "an assembly that never ran reports 0 / 28 and fails" "$out"; fi

# exactly at budget passes, and says how many did not run
trx s2 "$INTEG" 28 24 24 0 4
out=$(summary s2 "$INTEG	28" "$INTEG	4	four flaky skips"); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "4 test(s) never ran, within a declared budget"; then
    ok "at budget: passes and still prints the count and the reason"
else nope "at budget: passes and still prints the count and the reason" "$out"; fi

# one over budget fails
trx s3 "$INTEG" 28 23 23 0 5
out=$(summary s3 "$INTEG	28" "$INTEG	4	four flaky skips"); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "5 test(s) never ran, budget is 4"; then
    ok "one test over budget fails the gate"
else nope "one test over budget fails the gate" "$out"; fi

# under budget passes and asks for the budget to be tightened
trx s4 "$INTEG" 28 26 26 0 2
out=$(summary s4 "$INTEG	28" "$INTEG	4	four flaky skips"); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "lower it to 2"; then
    ok "under budget: passes and asks for the budget to be tightened"
else nope "under budget: passes and asks for the budget to be tightened" "$out"; fi

# a three-column row names its target: it reads <Assembly>.<target>.trx and
# is held to the assembly's budget
trx s9 "$INTEG.net10.0" 28 24 24 0 4
out=$(summary s9 "$INTEG	net10.0	28" "$INTEG	4	four flaky skips"); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "| \`$INTEG\` · \`net10.0\` | 24 / 28 |"; then
    ok "a target-qualified row reads its own .trx and the assembly's budget"
else nope "a target-qualified row reads its own .trx and the assembly's budget" "$out"; fi

# an unlisted assembly has a budget of zero
trx s5 "$UNIT" 199 198 198 0 1
out=$(summary s5 "$UNIT	199" ""); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "1 test(s) never ran, budget is 0"; then
    ok "an unlisted assembly gets a budget of zero"
else nope "an unlisted assembly gets a budget of zero" "$out"; fi

# skipped vs never reached are told apart
trx s6 "$INTEG" 20 16 16 0 4
out=$(summary s6 "$INTEG	28" ""); rc=$?
if printf '%s' "$out" | grep -q "| 4 | 8 |"; then
    ok "skipped (4) and never reached (8) are separate columns"
else nope "skipped (4) and never reached (8) are separate columns" "$out"; fi

# an empty discovery file is not a pass
mkdir -p "$tmp/s8"; : > "$tmp/s8/discovered.tsv"; : > "$tmp/s8/budget.tsv"
out=$("$repo_root/scripts/test-summary.sh" --results-directory "$tmp/s8" --budget "$tmp/s8/budget.tsv" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "empty report is not a pass"; then
    ok "an empty discovery file fails instead of printing a blank green table"
else nope "an empty discovery file fails instead of printing a blank green table" "$out"; fi

# the run summary is appended to the GitHub step summary
trx s7 "$UNIT" 199 199 199 0 0
export GITHUB_STEP_SUMMARY="$tmp/step-summary.md"
: > "$GITHUB_STEP_SUMMARY"
summary s7 "$UNIT	199" "" >/dev/null 2>&1
if grep -q "199 / 199" "$GITHUB_STEP_SUMMARY"; then ok "the table lands in \$GITHUB_STEP_SUMMARY"
else nope "the table lands in \$GITHUB_STEP_SUMMARY" "$(cat "$GITHUB_STEP_SUMMARY")"; fi
unset GITHUB_STEP_SUMMARY

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
