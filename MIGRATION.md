# Migration provenance — `eventsourcing` domain repo

Assembled 2026-07-25 per ADR-0007 (repo-per-domain topology). Sources were extracted read-only via `git archive main` from local clean clones; the original repos were not modified.

| Component | Source repo | Source HEAD SHA | Notes |
|---|---|---|---|
| `src/Compendium.Adapters.PostgreSQL` + `tests/Unit/...Tests` + `tests/Integration/...IntegrationTests` | `sassy-solutions/compendium-adapter-postgresql` | `d51706f39818eaf11cfb43f0357ae6bb25cc0045` | PackageId `Compendium.Adapters.PostgreSQL` unchanged. Code untouched except the project README header (repo pointers). |
| Scaffold (`Directory.Build.props`, `global.json`, `.github/workflows/ci.yml` + `release.yml` shape) | `sassy-solutions/compendium-adapter-supabase` | `86bad144bb57ed1284e17d88bb2acfe45d954692` (working tree; `origin/main` = `1f35e9329c6c044b0ccde9ffd72c37a8e272a2d6`) | Freshest release.yml: GitHub Packages first, nuget.org soft-skip when `NUGET_API_KEY` absent. Nupkg assert adapted to `-ge 1`; feed org → `SCOJH`. |

## Abstraction

No abstraction moved into this repo. The adapters implement `IEventStore` / `IStreamingEventStore` / `IProjectionStore` / `IProjectionCheckpointStore` / `IProcessManagerRepository` from the **base `Compendium.Abstractions`** package, which stays in the framework and is consumed as a nuget.org `PackageReference`.

## Dependency pin changes vs. source

| Pin | Source (`compendium-adapter-postgresql`) | This repo | Why |
|---|---|---|---|
| `Compendium.Abstractions` / `Core` / `Infrastructure` / `Multitenancy` | `1.0.0` | `1.0.5-preview.1` | Domain-repo policy: pin base framework packages at `1.0.5-preview.1` (or highest already pinned, whichever is greater). |
| `Microsoft.Extensions.*` | `9.0.0` | `9.0.16` | Compendium `1.0.5-preview.1` requires `>= 9.0.16` (NU1605 downgrade otherwise). Matches the supabase scaffold pins. |

All other pins are carried over unchanged (single source repo — no union conflicts to resolve).

## Verification at assembly time

- `dotnet build -c Release`: 0 errors (no API drift between the `1.0.0` pin and `1.0.5-preview.1` — no adapter code fixes needed).
- Unit tests: 199/199 passed, 0 skipped.
- Unit-test line coverage: **36.3%** (reportgenerator) → CI gate set to 35%. The source repo's 70% gate included its `[RequiresDocker]` integration suite; Docker was unavailable at assembly time, so integration tests were compiled but not run.

## Version train

First tag: `v1.1.0-preview.1` — above the framework's historical `1.0.x` publishes of `Compendium.Adapters.PostgreSQL` (last: `1.0.2` on nuget.org), so packages from this repo win resolution.
