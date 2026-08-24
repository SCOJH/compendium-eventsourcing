#!/usr/bin/env bash
#
# Runs the whole test surface of this repository and reports, per assembly,
# how many tests were *discovered* against how many actually *ran*.
#
# Why this exists instead of a bare `dotnet test`: CI used to run
#
#     dotnet test --filter "FullyQualifiedName!~IntegrationTests"
#
# which excluded every integration test by name. A green run therefore meant
# "the unit tests passed", but read as "the tests passed" — including on PRs
# whose acceptance criteria were covered only by integration tests. Nothing in
# the log distinguished "covered by a test that ran" from "covered by a test
# that exists".
#
# This script removes the filter, runs the integration lane when Docker is
# there, and — whatever happens — prints the discovered/executed delta per
# assembly. Tests that never ran are a number in the summary, not a silence.
#
# See docs/TESTING.md.

set -euo pipefail

DOTNET="${DOTNET:-dotnet}"
DOCKER="${DOCKER:-docker}"

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

configuration="Release"
results_dir="TestResults"
budget_file="tests/unrun-budget.tsv"
no_build=""
collect_coverage=1
integration_mode="auto"   # auto | require | skip

usage() {
    cat <<'USAGE'
Usage: scripts/run-tests.sh [options]

  -c, --configuration <cfg>     Build configuration (default: Release)
  -r, --results-directory <dir> Where .trx and coverage land (default: TestResults)
      --no-build                Do not build; assumes a prior `dotnet build`
      --no-coverage             Skip `--collect:"XPlat Code Coverage"`
      --require-integration     Fail the run if Docker is unavailable
      --skip-integration        Do not run the integration lane at all
      --budget <file>           Never-run budget (default: tests/unrun-budget.tsv)
  -h, --help                    This message

Exit code is non-zero if any test failed, or if an assembly left more tests
unrun than its budget allows.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--configuration)     configuration="$2"; shift 2 ;;
        -r|--results-directory)  results_dir="$2"; shift 2 ;;
        --no-build)              no_build="--no-build"; shift ;;
        --no-coverage)           collect_coverage=0; shift ;;
        --require-integration)   integration_mode="require"; shift ;;
        --skip-integration)      integration_mode="skip"; shift ;;
        --budget)                budget_file="$2"; shift 2 ;;
        -h|--help)               usage; exit 0 ;;
        *) echo "run-tests: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

cd "$repo_root"
mkdir -p "$results_dir"
discovered_file="$results_dir/discovered.tsv"
: > "$discovered_file"

# --- Preflight: establish Docker, do not assume it -------------------------
#
# The GitHub-hosted ubuntu-latest image ships Docker Engine, so the integration
# lane is expected to run on PRs. That is a claim about someone else's image,
# so the run states what it observed rather than trusting it.

docker_available=0
docker_probe=""
if docker_probe=$("$DOCKER" info 2>&1); then
    docker_available=1
    docker_server=$(printf '%s\n' "$docker_probe" | sed -n 's/^[[:space:]]*Server Version:[[:space:]]*//p' | head -1)
    echo "Preflight: \`docker info\` succeeded (server ${docker_server:-unknown})."
else
    echo "Preflight: \`docker info\` failed — no container runtime on this machine."
    printf '%s\n' "$docker_probe" | head -5 | sed 's/^/  | /'
fi

run_integration=0
case "$integration_mode" in
    skip)
        echo "Integration lane: disabled by --skip-integration."
        ;;
    require)
        if [ "$docker_available" -eq 1 ]; then
            run_integration=1
        else
            echo "Integration lane: --require-integration was passed and Docker is unavailable." >&2
            exit 1
        fi
        ;;
    auto)
        if [ "$docker_available" -eq 1 ]; then
            run_integration=1
            echo "Integration lane: enabled."
        else
            echo "Integration lane: skipped, Docker is unavailable."
            echo "  Its tests will be counted as never-run in the summary below."
        fi
        ;;
esac

# --- Which projects are we talking about? ----------------------------------
#
# An assembly belongs to the integration lane when it lives under
# tests/Integration/ or its name says so. Both conventions are checked because
# the old CI filter keyed off the *name*, and a rename must not silently move a
# project out of the lane.

is_integration_project() {
    case "$1" in
        tests/Integration/*) return 0 ;;
    esac
    case "$(basename "$1" .csproj)" in
        *IntegrationTests*|*LoadTests*) return 0 ;;
    esac
    return 1
}

projects=()
while IFS= read -r csproj; do
    projects+=("${csproj#./}")
done < <(find tests -name '*.csproj' | sort)

if [ "${#projects[@]}" -eq 0 ]; then
    echo "run-tests: no test project found under tests/." >&2
    exit 1
fi

# --- Discovery: how many tests EXIST, independent of any filter ------------
#
# `--list-tests` enumerates what the assembly contains. The .trx written by the
# run says what the runner actually executed. The gap between the two is the
# whole point of this script: a filter, a missing Docker, or an explicit
# [Fact(Skip=...)] all show up there, and none of them can hide behind a green
# check.

echo
echo "Discovering tests..."
for csproj in "${projects[@]}"; do
    assembly=$(basename "$csproj" .csproj)
    listing=""
    if ! listing=$("$DOTNET" test "$csproj" -c "$configuration" $no_build --list-tests 2>&1); then
        echo "  $assembly: discovery FAILED" >&2
        printf '%s\n' "$listing" | tail -20 | sed 's/^/    | /' >&2
        exit 1
    fi
    count=$(printf '%s\n' "$listing" | awk '
        /The following Tests are available/ { inlist = 1; next }
        inlist && /^[[:space:]]+[^[:space:]]/ { n++ }
        END { print n + 0 }')
    printf '%s\t%s\n' "$assembly" "$count" >> "$discovered_file"
    echo "  $assembly: $count"
done

# --- Run ------------------------------------------------------------------
#
# One `dotnet test` per project, so every assembly gets its own .trx and the
# report can attribute counts. A failing lane does not abort the loop: the
# summary is worth more than a fast exit, and the exit code is carried to the
# end.

coverage_args=()
[ "$collect_coverage" -eq 1 ] && coverage_args=(--collect:"XPlat Code Coverage")

tests_failed=0
echo
for csproj in "${projects[@]}"; do
    assembly=$(basename "$csproj" .csproj)
    if is_integration_project "$csproj" && [ "$run_integration" -eq 0 ]; then
        echo "--- $assembly: not run (integration lane disabled)"
        continue
    fi
    echo "--- $assembly: running"
    if ! "$DOTNET" test "$csproj" \
            -c "$configuration" $no_build \
            --logger "trx;LogFileName=${assembly}.trx" \
            --results-directory "$results_dir" \
            "${coverage_args[@]}"; then
        tests_failed=1
        echo "--- $assembly: FAILED"
    fi
done

# --- Report + gate ---------------------------------------------------------

echo
summary_failed=0
"$repo_root/scripts/test-summary.sh" \
    --results-directory "$results_dir" \
    --discovered "$discovered_file" \
    --budget "$budget_file" || summary_failed=$?

if [ "$tests_failed" -ne 0 ]; then
    echo "run-tests: at least one test failed." >&2
    exit 1
fi
if [ "$summary_failed" -ne 0 ]; then
    exit "$summary_failed"
fi
echo "run-tests: OK."
