# Testing

## The problem this replaces

CI ran its tests like this:

```yaml
dotnet test -c Release --no-build \
  --filter "FullyQualifiedName!~IntegrationTests"
```

Every integration test in the repository was excluded by name, and no other
workflow, job or schedule ran them. So a green check meant *the unit tests
passed*, while reading as *the tests passed*.

That is not a theoretical gap. PR #17 fixed a silent truncation in the
PostgreSQL event store: a stream that failed to deserialise came back short,
with no error. Its three acceptance criteria are covered by seven tests, all of
them in `tests/Integration/`, all seven excluded by that filter. The green check
on that PR came from 199 unit tests, none of which touched the fix. Closing the
ticket on it would have shipped the same failure one level up: a guarantee
displayed by something that never ran.

The filter itself was not careless — the suites need Docker, and the CI log said
so. The defect is that **nothing distinguished "covered by a test that runs"
from "covered by a test that exists"**. A green check said the same thing in
both cases.

## What runs now

`scripts/run-tests.sh` is the entry point, for CI and for local runs alike.

1. **Preflight.** It runs `docker info` and prints what it found. The
   GitHub-hosted `ubuntu-latest` image ships Docker Engine, so the integration
   lane is expected to run on every PR — but that is a claim about someone
   else's image, so the run states what it observed rather than assuming it.
2. **Discovery.** For each test project, `dotnet test --list-tests` counts what
   the assembly *contains*. This count is independent of any `--filter`, which
   is what makes a filter visible instead of invisible.
3. **Run.** Every test project runs unfiltered, each with its own `.trx`, so
   counts can be attributed per assembly. A failing lane does not abort the
   loop — the report is worth more than a fast exit — but it does fail the run.
4. **Report and gate.** `scripts/test-summary.sh` compares discovery against the
   `.trx` counters and writes the table below to stdout and to
   `$GITHUB_STEP_SUMMARY`.

```bash
bash scripts/run-tests.sh                       # build, run everything, report
bash scripts/run-tests.sh --no-build            # after a `dotnet build`
bash scripts/run-tests.sh --skip-integration    # unit lane only, offline (see below)
bash scripts/run-tests.sh --require-integration # fail if Docker is missing
bash scripts/selftest.sh                        # test the harness itself
```

## Reading the report

| Assembly | Executed / discovered | Passed | Failed | Skipped | Not reached | Gate |
|---|---:|---:|---:|---:|---:|---|
| `Compendium.Adapters.PostgreSQL.Tests` | 199 / 199 | 199 | 0 | 0 | 0 | OK |
| `Compendium.Adapters.PostgreSQL.IntegrationTests` | 24 / 28 | 24 | 0 | 4 | 0 | within budget |

*(Illustrative shape. The real numbers come from the run.)*

| Column | Meaning |
|---|---|
| **Discovered** | what `--list-tests` found in the assembly — every test that exists |
| **Executed** | what the runner actually ran: passed + failed |
| **Skipped** | what the runner saw and skipped — `[Fact(Skip = "…")]`, or a dynamic skip such as `[RequiresDockerFact]` with no Docker |
| **Not reached** | discovered − executed − skipped: excluded by a `--filter`, or the assembly never ran at all |

**Never run** is skipped + not reached, i.e. discovered − executed. It is the
number the gate looks at, and it is printed on every run whatever the outcome —
a figure, not a silence.

## The never-run budget

`tests/unrun-budget.tsv` caps, per assembly, how many tests may go unrun:

```
<assembly>	<max-unrun>	<reason>
```

An assembly absent from the file has a budget of 0: every test it contains must
run, or CI goes red. A budget is a ceiling, not a waiver — adding a test that
cannot run reddens CI until someone raises the number deliberately and writes
why in that third column. Lowering it is always safe, and the summary points out
when reality is better than the budget.

This is the mechanism behind the rule that matters: **a ticket whose acceptance
criterion rests on an integration test cannot be closed on a run that did not
execute it.** If the test did not run, the run says so and the count is in the
PR summary.

If this repository ever decides *not* to run its integration lane on PRs, that
decision goes in this file, with its reason, and the number of tests it costs is
printed on every run.

The same rule applies to the escape hatches. `--skip-integration` and a missing
Docker both leave 28 tests unrun against a budget of 4, so both exit non-zero.
Skipping the lane is allowed; calling the result green is not. Use the flag to
get a fast unit loop offline, and read the exit code as "you did not run
everything" rather than as a failure.

## Wiring it into CI

> The workflow files under `.github/` are **not** part of this change. Apply
> these two edits to enable the lane.

In `.github/workflows/ci.yml`, replace the body of the `Test (with coverage)`
step with a call to the script — it collects `XPlat Code Coverage` into the same
`TestResults/` directory, so the coverage step that follows needs no change:

```yaml
      - name: Test
        run: |
          bash scripts/run-tests.sh \
            --configuration Release \
            --no-build \
            --results-directory TestResults

      - name: Self-test the test harness
        run: bash scripts/selftest.sh
```

In `.github/workflows/release.yml`, replace the body of the `Test (unit only)`
step. A release must not ship on tests that did not run, so the integration lane
is required rather than merely attempted:

```yaml
      - name: Test
        run: |
          bash scripts/run-tests.sh \
            --configuration Release \
            --no-build \
            --results-directory TestResults \
            --require-integration
```

### The coverage gate

`ci.yml` gates line coverage at 35 % and its comment says: *"Raise this gate if
integration coverage is ever folded into CI."* That is now the case, and the
figure should go up — but by how much is a measurement, not a guess. Read the
percentage off the first green run with the integration lane enabled, then raise
the gate to just under it. It is left at 35 % here rather than set to an
invented number.

## Census — what exists in this repository

Counted from the source at the commit that introduced this document.

| Project | Test files | Tests | Executed with Docker | Never run |
|---|---:|---:|---:|---:|
| `tests/Unit/Compendium.Adapters.PostgreSQL.Tests` | — | 199 | 199 | 0 |
| `tests/Integration/Compendium.Adapters.PostgreSQL.IntegrationTests` | 3 test classes + 3 fixtures | 28 | 24 | 4 |

The integration assembly's 28 tests all carry `[RequiresDockerFact]`:

| File | Tests | Of which `Skip = …` |
|---|---:|---:|
| `EventStore/PostgreSqlEventStoreIntegrationTests.cs` | 16 | 1 — a timing-sensitive throughput assertion |
| `Projections/ProjectionManagerIntegrationTests.cs` | 8 | 3 — flaky event seeding |
| `Sagas/PostgresProcessManagerStateReloadTests.cs` | 4 | 0 |

Those four `Skip =` are the whole of the never-run budget. Each states its
reason at the test; none is a filter, and all four are visible in every run
summary rather than being absorbed into a green check.

The seven tests of PR #17, all in
`EventStore/PostgreSqlEventStoreIntegrationTests.cs`, none of them skipped:

- `GetEventsAsync_WhenTypeIsNotResolved_FailsInsteadOfReturningATruncatedStream`
- `GetEventsAsyncFromVersion_WhenTypeIsNotResolved_Fails`
- `GetEventsAsyncPaged_WhenTypeIsNotResolved_Fails`
- `GetEventsInRangeAsync_WhenTypeIsNotResolved_Fails`
- `GetLastEventAsync_WhenTypeIsNotResolved_NamesTheCauseInsteadOfBeingGeneric`
- `GetEventsAsync_WhenPayloadCannotBeRead_IsDistinguishedFromAnUnresolvedType`
- `GetEventsAsync_WhenEveryTypeResolves_StillReturnsTheWholeStream`

## Porting this to the sibling adapter repositories

Nothing here is specific to this repository: the runner discovers
`tests/**/*.csproj`, classifies a project as integration by its path
(`tests/Integration/`) or its name (`*IntegrationTests*`, `*LoadTests*` — both,
because a rename must not quietly move a project out of the lane), and the
budget file starts empty. Copying `scripts/run-tests.sh`,
`scripts/test-summary.sh`, `scripts/selftest.sh` and an empty
`tests/unrun-budget.tsv`, then applying the two workflow edits above, is the
whole port. The first run prints the census; whatever it reports becomes the
starting budget, line by line, with a reason.
