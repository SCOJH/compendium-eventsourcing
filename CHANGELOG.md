# Changelog

All notable changes to this repository are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are git tags
with a `v` prefix, read by MinVer (see `docs/RELEASE.md`); this file starts with
the change below, earlier releases are described by their GitHub Release notes.

## [Unreleased]

### Changed

- **`Compendium.Adapters.PostgreSQL` now targets `net9.0` and `net10.0`.** .NET 9
  (STS) leaves support on 2026-11-10; .NET 10 is the LTS consumers are moving to,
  and `net9.0` stays for the transition only (dropping it is a later ticket).
  `global.json` moves to the .NET 10 SDK (10.0.100 or any later 10.0 feature
  band), which builds both targets; the CI and release workflows install the
  .NET 9 SDK beside it for its runtime, and `scripts/run-tests.sh` runs every
  test project once per target, with one `.trx` per (assembly, target) and one
  report row each. `Microsoft.Extensions.*` is pinned once per target in
  `Directory.Packages.props`: the `net9.0` dependency group of the package asks
  for 9.0.19 — the three pins Dependabot had moved to 10.0.12 on the single
  `net9.0` target (`DependencyInjection.Abstractions`, `Logging.Abstractions`,
  `Options`) go back to the 9.x line, so .NET 9 consumers are no longer asked for
  10.x packages — and the `net10.0` group asks for 10.0.12, which Npgsql 10.0.3
  requires there (`Microsoft.Extensions.Logging.Abstractions >= 10.0.0`). The
  `net10.0` target also references `Microsoft.Extensions.Hosting.Abstractions`
  10.0.12 directly: `Compendium.Infrastructure` 1.0.5-preview.5 (a `net9.0`-only
  package) asks for 9.0.19 while its own dependency `OpenTelemetry.Extensions.Hosting`
  1.18.0 asks for `>= 10.0.0` on `net10.0`, a downgrade NuGet refuses (NU1605);
  the `net9.0` group does not carry it. The `Compendium.*` framework packages stay
  at 1.0.5-preview.5 (`net9.0` assets, which `net10.0` consumes as such). No API
  change. (NET10-01, agent-spot/backlog#363)
