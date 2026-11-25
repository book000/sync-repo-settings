# AGENTS.md

Guidance for AI coding agents and contributors. `CLAUDE.md` imports this file, and `.github/copilot-instructions.md` adds the review checklist.

## Language

- All deliverables are written in **English**: commit messages, PR/Issue titles and bodies, review comments, code comments and docstrings, and documentation (`README.md`, `AGENTS.md`, etc.).
- Exceptions (keep as is): quotations, technical identifiers, generated files, and external source text.
- Runtime messages (logs, errors, usage text, PR comments posted by workflows) are English.
- Do not rewrite Git history to change the language of past commits.

## Overview

`sync-repo-settings` is a Bash tool that applies a declarative configuration (`config.json`) to every repository of the owners listed in `targets` through the GitHub API (`gh api`). It manages repository merge settings, workflow permissions, Actions variables, Actions policies, rulesets and Copilot code review. See `README.md` for behavior and `config.json` format.

**It changes settings on real repositories.** Never run `./apply-settings.sh` without `--dry-run` unless that is the explicit intent. To exercise it safely, put a stub `gh` first (for example as an exported shell function), because `--dry-run` still performs read-only API calls against real repositories.

## Commands

Requirements: Bash 4+ (`readarray`), `gh` (authenticated), `jq`, `awk`.

```bash
./apply-settings.sh --dry-run                       # show what would change
./apply-settings.sh --dry-run --repo owner/repo     # one repository
./apply-settings.sh --dry-run --markdown            # Markdown output used for PR comments
./apply-settings.sh --help
bash tests/rulesets.sh                              # stubbed ruleset regression and dry run
bash -n apply-settings.sh                           # syntax check
shellcheck apply-settings.sh                        # SC2155 warnings are existing and accepted
bash tests/all-skip.sh                              # stubbed dry-run regression check
bash tests/temp-file-cleanup.sh                     # temp file cleanup regression
```

There is no lint workflow. Verify changes with `bash -n`, `shellcheck`, all regression fixtures, and a `--dry-run` against a stubbed `gh`.

## Structure

- `apply-settings.sh`: the whole tool. Functions: `evaluate_filter` (rule filters), `merge_settings` (defaults + matched rules), `apply_repo_settings`, `apply_workflow_permissions`, `apply_actions_variables`, `apply_actions_policies`, `detect_status_checks`, `apply_rulesets`, `apply_copilot_code_review`, then the main loop over targets and repositories.
- `check-pr-trigger.awk`: decides whether a workflow file runs on the whole PR lifecycle. Called by `check_pr_trigger_always_runs`; it must stay next to the script.
- `tests/all-skip.sh`: stubbed dry-run regression check for `_all` and skipped settings.
- `config.json`: `targets`, `defaults` (each setting has a `mode` and `values`, or a ruleset `template`; `actions_policies` uses an array for `values` instead of an object), and `rules` (a `filter` plus `settings` overrides, evaluated in order).
- `.github/workflows/sync.yml`: hourly run and manual dispatch (`target`, `dry_run` inputs); uses the `PERSONAL_ACCESS_TOKEN` repository secret.
- `.github/workflows/pr-preview.yml` and `pr-preview-comment.yml`: run `--dry-run --markdown` for a PR and post the result as a PR comment. Fork PRs need approval of the `pr-preview` Environment, and approving runs the PR's own `apply-settings.sh` with the PAT.
- `.github/workflows/keep-alive.yml`: twice a month, enables `keep-alive.yml` and `sync.yml` through the API so scheduled workflows are not auto-disabled.

## Conventions

- Keep `set -euo pipefail`, quote every variable expansion, and use `local` inside functions (not at top level).
- Call the API only through `gh_api`, which adds the `X-GitHub-Api-Version` header. Build `gh api` arguments as arrays; never interpolate user input into a shell string.
- Every mutating call must be skipped when `DRY_RUN=true` and must log what it would change.
- jq's `//` treats `false` as empty; test `== null` or use `has()` when a value can be `false`.
- Setting modes are `insert`, `upsert` (default) and `skip`; `skip` is protected from later rules. Document any change of semantics in `README.md`.
- When the config structure or the CLI options change, update the `usage` text in `apply-settings.sh`, `README.md`, and this file.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/); branches follow [Conventional Branch](https://conventional-branch.github.io) short form (`feat/...`, `fix/...`). The default branch is `master`.
- `actions_policies.values` is an array of policy objects sent verbatim, and its `allowed_events` list is hard-coded in `config.json` (never computed from workflow files). Extend it when GitHub adds new events to the Actions policies REST API (https://docs.github.com/en/rest/actions/policies), since a missing event is blocked for every workflow.
- Put a short purpose comment before each major function. Verify a config change on one repository (`--repo`) before applying it everywhere. If review expectations change, update `.github/copilot-instructions.md` too.
- Do not commit to Renovate PRs. Never commit secrets.
