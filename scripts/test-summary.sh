#!/usr/bin/env bash
#
# Turns a directory of .trx files into a per-assembly report of what actually
# ran, and fails the run when an assembly leaves more tests unrun than its
# declared budget allows.
#
# The report answers one question a green check cannot: of the tests that exist
# in this assembly, how many were executed? Four numbers make up the answer.
#
#   discovered   what `dotnet test --list-tests` found in the assembly
#   executed     what the runner ran — passed + failed
#   skipped      what the runner saw and skipped ([Fact(Skip=...)], or a
#                dynamic skip such as [RequiresDockerFact] with no Docker)
#   not reached  discovered - executed - skipped: excluded by a --filter, or
#                the assembly was never invoked at all
#
# "Never run" is skipped + not reached, i.e. discovered - executed. That is the
# number the gate compares against tests/unrun-budget.tsv. A budget is a
# ceiling, not a blanket waiver: adding a new never-run test reddens CI until
# someone raises the number on purpose and writes down why.
#
# See docs/TESTING.md.

set -euo pipefail

results_dir="TestResults"
discovered_file=""
budget_file="tests/unrun-budget.tsv"

usage() {
    cat <<'USAGE'
Usage: scripts/test-summary.sh [options]

  -r, --results-directory <dir>  Directory holding <Assembly>.trx (default: TestResults)
      --discovered <file>        TSV of "<assembly>\t<count>" (default: <dir>/discovered.tsv)
      --budget <file>            TSV of "<assembly>\t<max-unrun>\t<reason>"
  -h, --help                     This message

Exits 1 if any assembly exceeds its never-run budget.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -r|--results-directory) results_dir="$2"; shift 2 ;;
        --discovered)           discovered_file="$2"; shift 2 ;;
        --budget)               budget_file="$2"; shift 2 ;;
        -h|--help)              usage; exit 0 ;;
        *) echo "test-summary: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$discovered_file" ] || discovered_file="$results_dir/discovered.tsv"

if [ ! -f "$discovered_file" ]; then
    echo "test-summary: no discovery file at $discovered_file — cannot tell what exists from what ran." >&2
    exit 1
fi

# --- .trx parsing ----------------------------------------------------------
#
# VSTest writes a single <Counters .../> element per .trx whose attributes hold
# the totals. `executed` is total minus notExecuted, so it is exactly the count
# of tests that really ran.

counter_attr() {  # counter_attr <counters-element> <attribute>
    printf '%s' "$1" | sed -n "s/.*[[:space:]]$2=\"\([0-9]*\)\".*/\1/p"
}

budget_for() {  # budget_for <assembly> -> "<max>\t<reason>", default "0\t"
    local assembly="$1"
    if [ -f "$budget_file" ]; then
        awk -F'\t' -v a="$assembly" '
            /^[[:space:]]*#/ { next }
            NF == 0 { next }
            $1 == a { printf "%s\t%s\n", ($2 == "" ? 0 : $2), $3; found = 1; exit }
            END { if (!found) print "0\t" }
        ' "$budget_file"
    else
        printf '0\t\n'
    fi
}

rows=""
notes=""
gate_failed=0
total_discovered=0
total_executed=0
total_never_run=0

while IFS=$'\t' read -r assembly discovered; do
    [ -n "$assembly" ] || continue
    trx="$results_dir/$assembly.trx"

    executed=0; passed=0; failed=0; skipped=0
    if [ -f "$trx" ]; then
        counters=$(grep -o '<Counters[^>]*>' "$trx" | head -1) || true
        if [ -z "$counters" ]; then
            echo "test-summary: $trx has no <Counters> element — refusing to guess." >&2
            exit 1
        fi
        executed=$(counter_attr "$counters" executed); executed=${executed:-0}
        passed=$(counter_attr "$counters" passed);     passed=${passed:-0}
        failed=$(counter_attr "$counters" failed);     failed=${failed:-0}
        skipped=$(counter_attr "$counters" notExecuted); skipped=${skipped:-0}
    fi

    never_run=$(( discovered - executed ))
    [ "$never_run" -lt 0 ] && never_run=0
    not_reached=$(( never_run - skipped ))
    [ "$not_reached" -lt 0 ] && not_reached=0

    IFS=$'\t' read -r budget reason < <(budget_for "$assembly") || true
    budget=${budget:-0}

    if [ "$never_run" -gt "$budget" ]; then
        gate="**FAIL**"
        gate_failed=1
        notes+="- \`$assembly\`: $never_run test(s) never ran, budget is $budget."
        if [ "$not_reached" -gt 0 ]; then
            notes+=" $not_reached of them were never reached by the runner — a filter, or the assembly did not run at all."
        fi
        notes+=$'\n'
    elif [ "$never_run" -gt 0 ]; then
        gate="within budget"
        notes+="- \`$assembly\`: $never_run test(s) never ran, within a declared budget of $budget"
        [ -n "$reason" ] && notes+=" — $reason"
        notes+=$'\n'
        if [ "$never_run" -lt "$budget" ]; then
            notes+="  - the budget is now looser than reality; lower it to $never_run in \`$budget_file\`."$'\n'
        fi
    else
        gate="OK"
    fi

    rows+="| \`$assembly\` | $executed / $discovered | $passed | $failed | $skipped | $not_reached | $gate |"$'\n'

    total_discovered=$(( total_discovered + discovered ))
    total_executed=$(( total_executed + executed ))
    total_never_run=$(( total_never_run + never_run ))
done < "$discovered_file"

if [ -z "$rows" ]; then
    echo "test-summary: $discovered_file lists no assembly — an empty report is not a pass." >&2
    exit 1
fi

report=$(cat <<REPORT
## Tests executed, by assembly

| Assembly | Executed / discovered | Passed | Failed | Skipped | Not reached | Gate |
|---|---:|---:|---:|---:|---:|---|
${rows}| **Total** | **$total_executed / $total_discovered** | | | | **$total_never_run never ran** | |

REPORT
)

if [ -n "$notes" ]; then
    report+=$'\n\n'"### Tests that did not run"$'\n\n'"$notes"
fi

if [ "$gate_failed" -ne 0 ]; then
    report+=$'\n'"An assembly left more tests unrun than \`$budget_file\` allows. Either run them, or raise that budget with a written reason."$'\n'
fi

printf '%s\n' "$report"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$report" >> "$GITHUB_STEP_SUMMARY"
fi

exit "$gate_failed"
