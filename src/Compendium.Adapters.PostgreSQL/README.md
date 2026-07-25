# `Compendium.Adapters.PostgreSQL`

PostgreSQL adapter for the [Compendium](https://github.com/sassy-solutions/compendium) event-sourcing framework. JSONB-backed event store + projection checkpoint store + streaming event store + saga process-manager repository, all on raw [Npgsql](https://github.com/npgsql/npgsql).

Originally extracted from `sassy-solutions/compendium` per ADR-0006 (multi-repo adapter split); now maintained in the [`SCOJH/eventsourcing`](https://github.com/SCOJH/eventsourcing) domain repo per ADR-0007 (repo-per-domain topology). See `MIGRATION.md` at the repo root for provenance.

## What's in this package

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

```csharp
services.AddPostgreSqlEventStore(builder.Configuration.GetSection("Postgres"));
```

See [`docs/README.md`](docs/README.md) for full configuration (connection string, schema name, table name, BatchSize, multi-tenancy).

## Versioning

This package continues the version sequence of `Compendium.Adapters.PostgreSQL` originally published from the framework monorepo (last framework-published version: `1.0.0-preview.8`). The first release from this repo is `v1.0.0-preview.9`. Versions are driven by git tags via [MinVer](https://github.com/adamralph/minver) — see [`docs/RELEASE.md`](docs/RELEASE.md).

## Repository conventions

| Aspect | Choice |
|---|---|
| Target | .NET 9, C# 13 |
| DB driver | [Npgsql 9.0.x](https://www.nuget.org/packages/Npgsql) + [Dapper 2.1.x](https://www.nuget.org/packages/Dapper) |
| Test framework | xUnit 2.9.3 + FluentAssertions 6.12.1 + NSubstitute 5.1.0 |
| Integration tests | [Testcontainers](https://dotnet.testcontainers.org) 4.11.0 (Docker required) |
| Coverage gate | 199 unit tests, 90 %+ line coverage on the unit-testable surface |
| Result pattern | `Result<T>` from `Compendium.Core` |

## Build & test locally

```bash
# Unit tests — no Docker required.
dotnet test --filter "FullyQualifiedName!~IntegrationTests"

# Integration tests — Docker must be running (TestContainers spins up PostgreSQL).
dotnet test --filter "FullyQualifiedName~IntegrationTests"
```

The integration suite covers PG-specific behaviour that can't be tested against an in-memory implementation: JSONB serialisation round-trip, schema bootstrap, `WHERE global_position > @x` cursor semantics, tenant-filter SQL injection, snapshot UPSERT, process-manager state-row updates.

## License

[MIT](LICENSE) — Copyright © 2026 Sassy Solutions.
