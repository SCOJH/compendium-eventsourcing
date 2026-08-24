# Compendium — `eventsourcing` domain

Event-store persistence adapters for the [Compendium](https://github.com/sassy-solutions/compendium) event-sourcing framework, assembled per **ADR-0007** (repo-per-domain topology). This repo owns everything a service needs to persist and stream events durably: the adapters implement `IEventStore` and friends from the base `Compendium.Abstractions` package, which stays in the framework and is consumed here as a regular NuGet reference.

## Packages

| Package | Description |
|---|---|
| `Compendium.Adapters.PostgreSQL` | PostgreSQL event store: JSONB payloads, optimistic concurrency, multi-tenant isolation (RLS-safe tenant filters), streaming event store with global-position cursor, projection stores/checkpoints, saga process-manager repository. |

Package IDs are unchanged from their original single-adapter repos — upgrading is a version bump, not a rename.

## Components

| Component | Implements | Purpose |
|---|---|---|
| `PostgreSqlEventStore` | `IEventStore` | Durable event storage with optimistic concurrency, tenant isolation, JSONB payload |
| `PostgreSqlStreamingEventStore` | `IStreamingEventStore` | Global-position cursor for projection rebuilds + live processing |
| `PostgreSqlProjectionStore` | `IProjectionStore` | Projection checkpoints + snapshots + state |
| `PostgreSqlProjectionCheckpointStore` | `IProjectionCheckpointStore` | Fine-grained per-`(projection, aggregate)` checkpoints |
| `PostgresProcessManagerRepository` | `IProcessManagerRepository` | Durable saga state with typed-state reload |
| `RowLevelSecurityExtensions` | — | SQL-injection-safe tenant filter construction |

## Install

```bash
dotnet add package Compendium.Adapters.PostgreSQL
```

Packages publish to GitHub Packages (`https://nuget.pkg.github.com/SCOJH/index.json`) first, then nuget.org.

## Layout

```
src/
  Compendium.Adapters.PostgreSQL/       # the adapter (packable)
tests/
  Unit/Compendium.Adapters.PostgreSQL.Tests/                 # 199 unit tests, no Docker
  Integration/Compendium.Adapters.PostgreSQL.IntegrationTests/  # [RequiresDocker], Testcontainers PostgreSQL
```

## Build & test

```bash
dotnet build -c Release

# Everything: unit + integration. Docker must be running for the integration
# lane (Testcontainers spins up PostgreSQL); the script probes for it and says
# what it found.
bash scripts/run-tests.sh --no-build

# Unit lane only — no Docker, no network. Reports the integration tests as
# never-run and exits non-zero: skipping them is allowed, calling it green
# is not.
bash scripts/run-tests.sh --no-build --skip-integration
```

Each run prints, per assembly, how many of the tests it contains actually ran. Tests that did not run are a number in the summary, capped per assembly by `tests/unrun-budget.tsv` — not a silence behind a green check. See [`docs/TESTING.md`](docs/TESTING.md).

CI gates on unit-test line coverage (≥ 35% — the raw Npgsql/Dapper I/O surface is only exercised meaningfully by the integration suite; see the comment in `.github/workflows/ci.yml`).

## Versioning & releases

Versions derive from git tags via [MinVer](https://github.com/adamralph/minver) (`v` prefix). This repo's version train starts at `v1.1.0-preview.1` — deliberately above the framework's historical `1.0.x` publishes of the same package IDs, so domain-repo packages win resolution. Tag → `.github/workflows/release.yml` packs and publishes. See `docs/RELEASE.md`.

## Provenance

See [MIGRATION.md](MIGRATION.md) for the component → source-repo → SHA map.

## License

[MIT](LICENSE) — Copyright © 2026 Sassy Solutions.
