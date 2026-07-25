# Releasing a new version

This adapter ships a single NuGet package on tag pushes. Releases are produced by `.github/workflows/release.yml`.

## Cutting a release

1. Bump nothing in code — versions are derived from git tags via [MinVer](https://github.com/adamralph/minver).
2. Tag the commit you want to release with a `v` prefix :
   ```bash
   git tag v1.0.0-preview.8
   git push origin v1.0.0-preview.8
   ```
3. The `Release` workflow restores → builds → tests → packs the single `Compendium.Adapters.<Vendor>.csproj` → pushes to nuget.org and to GitHub Packages → creates a GitHub Release with auto-generated notes.
4. Verify on https://www.nuget.org within 5 min.

## Versioning policy

- **Continuity** : the first tag on a new adapter repo MUST be the next version that the framework would have published for this `PackageId` (e.g. if the framework last published `1.0.0-preview.8`, the new repo's first tag is `v1.0.0-preview.9`).
- Use [Semver](https://semver.org). Preview/RC/alpha/beta tags trigger `prerelease: true` on the GitHub Release.
- Breaking changes : bump major when stable, or move to the next preview number while < 1.0.

## Required secrets

| Secret | Where | Purpose |
|---|---|---|
| `NUGET_API_KEY` | Repo or org secret | Push to nuget.org |
| `GITHUB_TOKEN` | Auto-provided | Push to GitHub Packages + create release |

For `SCOJH` domain repos, `NUGET_API_KEY` should be an **organization secret** shared with all matching repos so each new adapter can release without manual setup.

## Troubleshooting

- **`dotnet pack` produces 0 nupkgs** : the adapter project's csproj must have `<IsPackable>true</IsPackable>`. The template ships this enabled.
- **Two nupkgs produced** : the test project is being packed by accident. Verify `tests/Unit/.../*.csproj` has `<IsPackable>false</IsPackable>` (template default).
- **nuget.org returns 409 / duplicate** : `--skip-duplicate` flag swallows this — the version is already published. Bump the tag.
- **MinVer infers `0.0.0-alpha.0` from a tag** : the tag prefix is wrong. The pinned prefix is `v` (declared in `Directory.Build.props` via `<MinVerTagPrefix>v</MinVerTagPrefix>`).
- **Build fails because `Compendium.Abstractions.X` can't be resolved** : check `Directory.Packages.props` pins to a published version. The framework's preview chain is at https://nuget.org/packages/Compendium.Abstractions.
