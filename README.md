# sync-repo-settings

A Bash tool that keeps GitHub repository settings consistent across all repositories of one or more owners (users or organizations). Desired state lives in [`config.json`](config.json); `apply-settings.sh` reads it, compares it with each repository through the GitHub API (`gh api`), and applies the differences.

> **Warning:** without `--dry-run` this changes settings on real repositories. Always start with `--dry-run`.

## What it changes

For every repository of every target owner, the following are managed (each can be set to `insert`, `upsert` or `skip`, see [Modes](#modes)):

| Setting key | What is changed | API |
|---|---|---|
| `repo_settings` | Repository options such as merge methods, squash commit format, auto-merge, branch deletion on merge (any key of the update-repository API listed under `values`) | `PATCH /repos/{owner}/{repo}` |
| `workflow_permissions` | Default `GITHUB_TOKEN` permissions and whether Actions can approve PR reviews | `PUT /repos/{owner}/{repo}/actions/permissions/workflow` |
| `actions_variables` | Repository Actions variables (name/value pairs) | `POST`/`PATCH /repos/{owner}/{repo}/actions/variables` |
| `actions_policies` | Repository Actions policies, by default one policy that allows every Actions event (so GitHub's default block of `pull_request_target` cannot break workflows) | `POST`/`PUT /repos/{owner}/{repo}/actions/policies` |
| `rulesets` | Creates a branch ruleset from a template, and reconciles its configured rules, enforcement, conditions and bypass actors | `POST`/`PUT /repos/{owner}/{repo}/rulesets` |
| `copilot_code_review` | The `copilot_code_review` rule of every existing ruleset of the repository | `PUT /repos/{owner}/{repo}/rulesets/{id}` |

The shipped defaults (squash-merge-only repository settings, workflow permissions, the `COPILOT_AGENT_FIREWALL_ENABLED` variable, the `Allow all Actions events` policy, a `master` ruleset template) and the per-repository `rules` (skipping archived repositories and forks, exceptions for individual repositories) are defined in [`config.json`](config.json), which is the source of truth.

## Prerequisites

- Bash 4 or later (the script uses `readarray`), `jq`, `awk`, and the [GitHub CLI](https://cli.github.com/) (`gh`), authenticated through `gh auth login` or the `GH_TOKEN` environment variable.
- The token must be able to read repositories of every target owner and, for a real run, change their settings, Actions variables and rulesets (admin access to the repositories). The exact minimal token scopes have not been verified. `GITHUB_TOKEN` of a workflow is not enough because it only reaches one repository; the workflows in this repository use a personal access token stored in the `PERSONAL_ACCESS_TOKEN` repository secret.
- Creating rulesets needs a plan that supports them for the repository; an HTTP 403 on creation is reported as a skip, not as a failure.
- Managing Actions policies needs repository Administration permission; an HTTP 403 (or 404) when listing, or an HTTP 403 when creating or updating a policy, is reported as a skip.

## Usage

```bash
./apply-settings.sh --dry-run                       # show what would change, apply nothing
./apply-settings.sh                                 # apply to every target in config.json
./apply-settings.sh --target tomacheese             # only one owner
./apply-settings.sh --repo tomacheese/my-repo       # only one repository
./apply-settings.sh --dry-run --markdown            # Markdown summary on stdout (used for PR comments)
./apply-settings.sh --verbose                       # debug output, including unchanged settings
./apply-settings.sh my-config.json                  # use another config file
```

| Option | Description |
|---|---|
| `-n`, `--dry-run` | Do not apply anything; log what would be applied. Read-only API calls are still made. |
| `-t`, `--target OWNER` | Process only this owner instead of the `targets` in the config. |
| `-r`, `--repo OWNER/REPO` | Process only this repository. Takes precedence over `--target`. |
| `-v`, `--verbose` | Print `[DEBUG]` lines (matched rules, skipped or unchanged settings). |
| `-m`, `--markdown` | Print a Markdown summary of the planned changes to stdout. Changes are only listed together with `--dry-run`. |
| `-h`, `--help` | Show usage. |
| `[CONFIG_FILE]` | Positional argument; defaults to `config.json` next to the script. |

Progress and errors go to stderr; stdout carries only the Markdown output. A failing `repo_settings` or `workflow_permissions` API call, a ruleset creation that fails with anything other than HTTP 403, and failures of Actions variables, Actions policies, ruleset updates and Copilot review are logged and skipped, and the run continues with the next section and repository. The exit status stays 0 in these cases.

Run `bash tests/all-skip.sh` to check that `_all` rules preserve skipped settings using a stubbed GitHub CLI.

## Configuration

`config.json` has three top-level keys.

```jsonc
{
  "targets": ["tomacheese", "book000"],      // owners to process
  "defaults": { "<setting key>": { "mode": "upsert", "values": { ... } } },
  "rules": [ { "name": "...", "filter": { ... }, "settings": { ... } } ]
}
```

### Modes

| Mode | Behavior |
|---|---|
| `upsert` (default) | Create or update. Existing values are overwritten. |
| `insert` | Only effective for `actions_variables` (existing variables are kept), `actions_policies` (nothing is created when the repository already has any policy), `rulesets` (existing rulesets are not modified, only created when missing) and `copilot_code_review` (an existing rule is not changed, a missing one is added). `repo_settings` and `workflow_permissions` treat `insert` like `upsert`. |
| `skip` | Do nothing for this setting. |

### Settings

A setting key that is absent from the effective settings of a repository (`defaults` plus the matched `rules`) is skipped and logged with `--verbose`. A key mentioned by a rule, including through `_all`, counts as configured. Inside a configured setting, a missing value key still uses a built-in fallback (`workflow_permissions` falls back to `write` and `true`, and `copilot_code_review` to `true` for both parameters). Set `"mode": "skip"` explicitly to disable a setting that is present.

- `repo_settings.values`: keys and values sent to the update-repository API. Booleans and numbers are sent as typed values, everything else as strings. Only keys that differ from the current state are reported.
- `workflow_permissions.values`: `default_workflow_permissions` (`read` or `write`) and `can_approve_pull_request_reviews`.
- `actions_variables.values`: variable name to value.
- `actions_policies.values`: an array of policy objects (`name`, `enforcement`, `rules`) sent to the create-policy API as they are. The shipped default is one policy, `Allow all Actions events`, with `enforcement: active`, no `conditions` (it targets every workflow) and one `restrict_action_events` rule that lists every supported event. Only repository-level policies are read (`has_parents=false`). With `insert` (the default) nothing is created when the repository already has any policy. With `upsert`, a policy is matched by its `name`; it is created when missing and updated (`PUT`) when its `enforcement` or `rules` differ, and policies with other names are never touched. Nothing is created or updated when the existing policies cannot be listed. A rule that sets `values` replaces the whole array. Organization-level policies and actor restrictions are not managed.
  - **Maintenance:** `allowed_events` is hard-coded in [`config.json`](config.json) and is not computed from the workflows. An event missing from the list is blocked for every workflow of the repository, so extend the list whenever GitHub adds a new event to the [Actions policies REST API](https://docs.github.com/en/rest/actions/policies).
- `rulesets`: `create_if_missing` (default `true`) and `template`. The script matches a repository-owned ruleset by template `name` and `target`; inherited and differently named rulesets do not count as matches. If multiple owned rulesets match, synchronization is skipped. A missing match is created only when `create_if_missing` is true and at least one status check was detected. In `upsert` mode, the template controls enforcement, conditions, deletion and non-fast-forward rules, and the configured pull request, status check and Copilot parameters. Unconfigured parameters and unrelated rules are preserved. Detected status checks replace existing checks only when detection yields at least one check. Configured bypass actors are added or updated while other existing actors are preserved. The admin bypass actor is always added or set to `pull_request` (`OrganizationAdmin` for an organization, `RepositoryRole` with `actor_id` 5 for a user). `insert` leaves a matching ruleset unchanged.
- `required_status_checks` template options: `detection` (`auto`), `exclude_patterns` (case-insensitive regular expressions matched against workflow and job names), `prefer_finished_jobs`, plus any ruleset parameter such as `strict_required_status_checks_policy`.
- `copilot_code_review.values`: `review_on_push` and `review_draft_pull_requests`, applied to every ruleset of the repository (a missing rule is added).

### Status check detection

For each workflow file in `.github/workflows` the script keeps the ones that run for the whole PR lifecycle (`check-pr-trigger.awk`: a `pull_request` or `pull_request_target` trigger without a `paths` or `paths-ignore` filter, and with either no `types` or all of `opened`, `reopened` and `synchronize`). From the latest finished run of each kept workflow (falling back to the latest run) it takes one job name as the required check; with `prefer_finished_jobs` a job named like `finished-xxx` or `xxx finished` wins over the first job. Workflows with no run yet contribute nothing.

### Rules

`rules` are evaluated in order for each repository. Every matching rule is deep-merged over `defaults` (objects are merged, other values replaced). A `filter` is a set of conditions that must all hold; an empty filter matches everything. A boolean filter value of `false` matches only repositories where the property is false; only a missing or `null` key skips the condition. Likewise, an explicit `false` for `can_approve_pull_request_reviews`, `create_if_missing` or `prefer_finished_jobs` is honored, and only a missing or `null` value falls back to the default.

| Filter key | Matches |
|---|---|
| `is_archived`, `is_fork`, `is_template` | The repository flag equals the value |
| `visibility` | `public`, `private` or `internal` |
| `language` | Primary language equals the value |
| `name_pattern` | Repository name matches the extended regular expression (`grep -E`) |
| `name_in`, `name_not_in` | Repository name is in / not in the array |
| `has_pr_workflow` | The repository has (`true`) or lacks (`false`) a workflow that runs for the whole PR lifecycle |

In `settings`, use a setting key to override that setting, or `_all` to override all six at once (for example `"_all": { "mode": "skip" }`). Once a setting has `mode: skip`, later rules cannot override it.

## Workflows

- **Sync Repository Settings** (`sync.yml`): runs every hour and on manual dispatch (inputs `target` and `dry_run`). Needs the `PERSONAL_ACCESS_TOKEN` secret.
- **PR Preview** and **PR Preview Comment** (`pr-preview.yml`, `pr-preview-comment.yml`): for pull requests to `master`, run `apply-settings.sh --dry-run --markdown` with the PR's code and post (or update) the result as a PR comment. Pull requests from forks need approval of the `pr-preview` Environment; approving runs the PR's own `apply-settings.sh` with the cross-repository token, so review the diff first.
- **Keep Alive** (`keep-alive.yml`): on the 1st and 15th of each month, calls the enable-workflow API for `keep-alive.yml` and `sync.yml` so GitHub does not disable them after 60 days of inactivity.
