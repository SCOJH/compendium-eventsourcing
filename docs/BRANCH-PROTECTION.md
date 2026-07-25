# Branch protection (recommended)

Apply these rules to `main` in every adapter repo created from this template.

## Required checks

- `build-test` — from `.github/workflows/ci.yml`. Includes the **≥ 35 % line-coverage gate** on the unit-test surface (raw DB I/O is integration-only; see ci.yml).
- `Analyze (csharp)` — GitHub-default CodeQL setup, language scanning.
- `CodeQL` — combined CodeQL workflow.

## Rules

| Setting | Value | Why |
|---|---|---|
| Require PR before merging | ✅ | No direct pushes to `main` |
| Required approvals | 1 | Keeps OSS contributions reviewable without slowing solo work |
| Dismiss stale approvals on new push | ✅ | Force reviewers to re-check after force-pushes |
| Require status checks to pass | ✅ | The three checks above |
| Require branches to be up to date | ✅ | Forces rebase against `main` before merge |
| Require signed commits | ✅ | Supply-chain hygiene |
| Require linear history | ✅ | No merge commits; use squash or rebase |
| Block force pushes (to `main`) | ✅ | Tag history is immutable |
| Allow administrator override | ⚠️ Optional | Default off ; the org owner can flip on for emergency fixes |

## How to apply

Via the GitHub web UI : *Settings → Branches → Add rule → Branch name pattern: `main`*

Or via API once for any new adapter repo :
```bash
gh api -X PUT repos/sassy-solutions/<adapter-repo>/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["build-test", "Analyze (csharp)", "CodeQL"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_signatures": true
}
JSON
```

## Secrets to set at repo level (or inherit from org)

- `NUGET_API_KEY` — for `.github/workflows/release.yml` to publish to nuget.org.

`GITHUB_TOKEN` is auto-provided ; no manual setup.

## Renovate / Dependabot

Both run automatically once the repo exists. Renovate config in `.github/renovate.json` opens grouped PRs for `Compendium.*` packages on every framework release (manual review required) and weekly Monday batched PRs for other deps (patch + minor auto-merge enabled).
