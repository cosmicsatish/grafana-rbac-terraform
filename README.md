# Grafana RBAC — GitOps Configuration

Declarative, YAML-driven Grafana RBAC management via Terraform. Define teams, roles, folders, and LBAC rules in plain YAML — Terraform and GitHub Actions handle provisioning automatically.

> **Generic & Portable** — no Grafana-instance-specific values are hardcoded in the Terraform modules.
> Swap the YAML config files and provider credentials to manage any Grafana Cloud or self-hosted instance.

---

## Table of Contents

- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Project Structure](#project-structure)
- [Configuration Reference](#configuration-reference)
  - [Roles](#roles-configrolesyaml)
  - [Folders](#folders-configfoldersyaml)
  - [Teams](#teams-configteamsyaml)
- [Onboarding a New Team](#onboarding-a-new-team)
- [Adding a New Folder](#adding-a-new-folder)
- [Adding or Modifying Custom Roles](#adding-or-modifying-custom-roles)
- [Idempotency & Safety Guarantees](#idempotency--safety-guarantees)
- [Validation Checks](#validation-checks)
- [CI/CD Pipelines](#cicd-pipelines)
- [Local Development](#local-development)
- [Variables Reference](#variables-reference)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    YAML Configuration                       │
│  config/roles.yaml   config/folders.yaml                    │
│  config/teams.yaml                                          │
└──────────────────────────┬──────────────────────────────────┘
                           │ read by
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  locals.tf — parses YAML, expands defaults, normalises      │
│  → produces final_roles, final_folders, final_teams         │
└──────────────────────────┬──────────────────────────────────┘
                           │ feeds
                           ▼
┌───────────────────────────────────────────────────────────────┐
│              terraform/main.tf (module orchestration)         │
│                                                               │
│   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌────────┐   │
│   │  roles   │──▶│ folders  │──▶│  teams   │──▶│  lbac  │   │
│   └──────────┘   └──────────┘   └──────────┘   └────────┘   │
│                                                               │
│   Creates         Creates         Creates teams,   Applies   │
│   custom roles    2-level         assigns roles,   LBAC      │
│   with inherited  folder          folder perms,    rules &   │
│   permissions     hierarchy       AD/LDAP sync     datasource│
│                                                    query perms│
└───────────────────────────────────────────────────────────────┘
                           │
                           ▼
                    Grafana Instance
```

**Data flow**: YAML config → `locals.tf` (load & expand defaults) → `validations.tf` (catch errors early) → modules (provision Grafana)

**Self-healing imports**: `grafana_discovery.tf` queries the live Grafana API at plan time and automatically imports any already-existing resources into state — no manual `terraform import` steps needed.

---

## Quick Start

### Prerequisites

- Terraform `1.15.4` (pinned — see [Version Pinning](#version-pinning))
- Grafana service account token with Admin role
- Grafana ≥ 11.5.0 (required for LBAC API support)

### Setup

```bash
# 1. Clone the repository
git clone <repo-url> && cd grafana-rbac-terraform

# 2. Set credentials
export TF_VAR_grafana_url="https://your-grafana.example.com"
export TF_VAR_grafana_token="glsa_your_service_account_token"

# 3. Initialise and plan
cd terraform
terraform init
terraform plan      # Review changes — no modifications until you approve
terraform apply     # Provision to Grafana
```

### First Run vs Subsequent Runs

| Scenario | What happens |
|----------|-------------|
| **First run** | Creates all roles, folders, teams, LBAC rules, and datasource permissions in a **single apply** |
| **Subsequent run (no config changes)** | `terraform plan` shows **0 changes** (fully idempotent) |
| **Config change** | Only the affected resources are updated, created, or destroyed |

> **Single-apply provisioning**: Adding a new team to `teams.yaml` and running `terraform apply` creates the team **and** sets up its LBAC rules and datasource permissions in one shot — no second apply needed.

---

## Project Structure

```
grafana-rbac-terraform/
├── config/                          ← YAML configuration (edit these)
│   ├── roles.yaml                   ← Custom role definitions (sorted A-Z)
│   ├── folders.yaml                 ← Folder hierarchy + default permissions (sorted A-Z)
│   └── teams.yaml                   ← All team definitions — source of truth (sorted A-Z)
│
├── modules/                         ← Reusable Terraform modules
│   ├── roles/                       ← grafana_role resources
│   ├── folders/                     ← grafana_folder resources (2-level hierarchy)
│   ├── teams/                       ← grafana_team + role assignments + folder perms + AD sync
│   └── lbac/                        ← LBAC rules + datasource query permissions
│
├── terraform/                       ← Root module (orchestration)
│   ├── main.tf                      ← Module wiring: roles → folders → teams → lbac
│   ├── locals.tf                    ← YAML parsing, default expansion, normalisation
│   ├── variables.tf                 ← Input variables (grafana_url, grafana_token, etc.)
│   ├── validations.tf               ← Precondition checks (block invalid config at plan time)
│   ├── providers.tf                 ← Grafana provider + hashicorp/http (versions pinned)
│   └── grafana_discovery.tf         ← Auto-import existing Grafana resources via API
│
├── tests/
│   └── test_scenarios.sh            ← Automated scenario test suite
│
└── .github/
    ├── actions/tf-state/            ← Composite action: persist/restore terraform.tfstate
    └── workflows/
        ├── team-onboarding.yml      ← Self-service team onboarding (creates PR)
        ├── terraform-plan.yml       ← Plan on PR
        ├── terraform-apply.yml      ← Apply (manual dispatch, requires confirmation)
        └── terraform-destroy.yml    ← Destroy (manual dispatch, requires confirmation)
```

---

## Configuration Reference

### Roles (`config/roles.yaml`)

Defines custom RBAC roles with granular permissions. Each role can inherit from Grafana built-in fixed roles or declare direct action/scope pairs. Roles are sorted alphabetically.

**Syntax**:

```yaml
my_custom_role:
  description: "Human-readable description"
  default: true                        # Optional — auto-assign to all teams
  auto_assign_to_folder_owner: true    # Optional — auto-assign to teams with an owner folder
  permissions:
    # Inherit all permissions from a Grafana built-in role
    fixed:reports:writer: ""

    # Direct action + scope pair
    dashboards:read: "dashboards:*"
```

- Prefix `fixed:` or `plugins:` → inherits all permissions from that built-in role
- Any other key → treated as a direct `action: scope` pair
- Empty scope `""` → uses the built-in role's default scope
- `default: true` → role is automatically assigned to every team
- `auto_assign_to_folder_owner: true` → role is automatically assigned to teams that declare an owner `folder`

**Scope overrides when inheriting from built-in roles**:

| Custom scope prefix | Which built-in permissions get the override |
|--------------------|--------------------------------------------|
| `datasources:` | Only `datasources:*` permissions |
| `folders:` or `dashboards:` | Folder, dashboard, and alerting permissions |
| Anything else | Applied as fallback override |

> **Note**: Certain built-in role scopes are automatically filtered out because they are invalid in custom roles: `receivers:type:`, `receivers:uid:`, `routingtrees:`, `inhibition-rules:`.

---

### Folders (`config/folders.yaml`)

Defines a flat **2-level folder hierarchy**: one root folder + child folders underneath. Folders are sorted alphabetically.

**Syntax**:

```yaml
my-new-folder:
  parent_key: osttra                   # Must reference a root-level folder key
  description: "What this folder is for"
  default_permissions:                 # Optional — auto-grant to all teams
    all_teams: View                    # View, Edit, or Admin
```

Folders with `default_permissions.all_teams` automatically grant the specified permission level to every team — no need to repeat it in each team's config.

> **Note**: `parent_uid` is accepted as a backward-compatible alias, but new entries should use `parent_key` since the value references a config key, not a live Grafana UID.

> **Safety**: Folders have `prevent_destroy_if_not_empty = true` by default — Terraform refuses to delete a folder that still contains dashboards or alert rules.

---

### Teams (`config/teams.yaml`)

The **single source of truth** for all teams. Each team entry only needs to declare what's unique to that team — everything else is auto-assigned by smart defaults. Teams are sorted alphabetically.

#### Global Config Defaults

```yaml
defaults:
  owner_folder_permission: Admin
  datasources:
    - loki-lbac                        # LBAC-enabled Loki datasource
  lbac_selectors:
    - '{ business_unit!~"reset|trioptima|osttra" }'
```

#### Smart Defaults

| Default | Source | How to override |
|---------|--------|-----------------:|
| `viewer_readonly` role | `roles.yaml` → `default: true` | Add extra roles in `roles:` list |
| `dashboard_folder_writer` role | `roles.yaml` → `auto_assign_to_folder_owner: true` | Already automatic for teams with `folder`; no override needed |
| `shared: View` permission | `folders.yaml` → `default_permissions` | Set `shared: Edit` or `shared: Admin` in `folder_permissions` |
| Owner folder permission | `teams.yaml` → `defaults.owner_folder_permission` | Set explicit permission level in `folder_permissions` |
| Default datasources | `teams.yaml` → `defaults.datasources` | Set `datasources: [...]` to override, or `[]` to opt out |
| Default LBAC selector | `teams.yaml` → `defaults.lbac_selectors` | Define `lbac:` list, or `datasources: []` to opt out |

#### Team Fields

| Field | Required | Description |
|-------|----------|-------------|
| `email` | Optional | Team contact email |
| `folder` | Optional | Owner folder key — auto-grants default owner permission + auto-assigns folder owner role |
| `folder_permissions` | Optional | Extra folder access beyond defaults |
| `group_uid` | Optional | Azure AD / LDAP group UUID for SSO sync |
| `roles` | Optional | Extra roles beyond auto-assigned defaults |
| `datasources` | Optional | Defaults to `defaults.datasources`. Set to `[]` to assign none. |
| `lbac` | Optional | Log-based access control selectors. Defaults to `defaults.lbac_selectors` if omitted. |

#### Examples

**Minimal team** — just an email, everything else is auto-assigned:

```yaml
teams:
  My Team:
    email: my-team@company.com
```

> Auto-gets: `viewer_readonly` role, `shared: View`, `loki-lbac` datasource query permission, default LBAC selector.

**Team with owner folder** — add a folder and LBAC:

```yaml
teams:
  My Team:
    email: my-team@company.com
    folder: my-team-folder
    group_uid: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    lbac:
      - '{ business_unit="myunit" }'
```

> Auto-gets: everything above + `dashboard_folder_writer` role + `my-team-folder: Admin`.

**Team with extra permissions** — override defaults as needed:

```yaml
teams:
  My Special Team:
    email: special@company.com
    folder: special-folder
    group_uid: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    roles:
      - alerting_writer
      - governance_reader
    folder_permissions:
      shared: Edit                      # Override default View → Edit
      executive: View
    lbac:
      - '{ business_unit="special" }'
```

---

## Onboarding a New Team

### Option 1: GitHub Actions UI (recommended)

1. Go to **Actions → Team Onboarding → Run workflow**
2. Fill in the form:
   - Team name, email
   - Owner folder (auto-created if it doesn't exist)
   - AD group UID (strongly recommended for SSO sync)
   - Extra roles, LBAC selectors, folder permissions (all optional — smart defaults apply)
3. A PR is created automatically with the team config
4. `terraform plan` runs on the PR for review
5. Merge the PR → `terraform apply` provisions the team **in a single apply** (team + LBAC + permissions)

The workflow also:
- **Auto-creates the owner folder** in `folders.yaml` if it doesn't exist
- **Warns in the PR** if no AD group UID is provided
- **Documents auto-assigned defaults** in the PR description

### Option 2: Manual YAML edit

1. Add the team entry to `config/teams.yaml` (maintain alphabetical order)
2. If a new folder is needed, add it to `config/folders.yaml` (maintain alphabetical order)
3. Open a PR → `terraform plan` validates the change
4. Merge → `terraform apply` provisions everything in one go

### Onboarding checklist

- [ ] Add team entry to `config/teams.yaml` (email is the only required field)
- [ ] Create an owner folder in `config/folders.yaml` if the team needs a private workspace
- [ ] Provide `group_uid` for Azure AD / LDAP sync (strongly recommended)
- [ ] Define `lbac` selectors only if the team needs custom log access control
- [ ] Add extra `roles` or `folder_permissions` only if defaults aren't sufficient
- [ ] Review the generated `terraform plan` output before merging

---

## Adding a New Folder

Add one entry to `config/folders.yaml` (maintain alphabetical order):

```yaml
my-new-folder:
  parent_key: osttra
  description: "My team workspace"
```

**Rules enforced by validation**:
- Folder names must not contain `/` characters
- Folders can only be nested 2 levels deep (root + child) — 3rd level is rejected at plan time
- Deleting a folder that contains dashboards/alerts is blocked by `prevent_destroy_if_not_empty`

---

## Adding or Modifying Custom Roles

Add or edit entries in `config/roles.yaml` (maintain alphabetical order):

```yaml
my_new_role:
  description: "What this role does"
  permissions:
    # Inherit from built-in roles
    fixed:dashboards:reader: ""
    # Direct permissions
    dashboards:write: "dashboards:*"
```

Then reference the role in a team's `roles` list.

---

## Idempotency & Safety Guarantees

`terraform plan` shows **zero changes** after a clean `terraform apply`. All known sources of drift are mitigated:

| Resource | Drift Source | Protection |
|----------|-------------|------------|
| `grafana_role` | Server-side version counter bumps | `lifecycle { ignore_changes = [version] }` |
| `grafana_team` | Members added via UI or AD/LDAP sync | `ignore_externally_synced_members = true` + `ignore_changes = [members]` |
| `grafana_folder` | Accidental deletion orphans dashboards | `prevent_destroy_if_not_empty = true` |
| `grafana_data_source_config_lbac_rules` | Selector list ordering differences | `sort(distinct())` before `jsonencode()` |
| `grafana_team_external_group` | Group list ordering from API | `sort()` on merged output |
| Role/folder permissions | Other teams' permissions | Uses individual `_item` resources — only manages what's declared |

### Safe merge strategy

- **LBAC rules**: Reads existing rules from Grafana, overlays declared rules on top. Teams not in this repo keep their existing selectors untouched. Only the specific team's UID key in the rules map is updated when that team's selectors change.
- **External groups**: Reads existing groups, merges with declared groups. Groups added outside Terraform are preserved.
- **Folder permissions**: Uses `grafana_folder_permission_item` (not `grafana_folder_permission`), so permissions set by other automation or the UI are not affected.
- **Role assignments**: Uses `grafana_role_assignment_item` (not `grafana_role_assignment`), so assignments from other sources are preserved.

---

## Validation Checks

Terraform runs **8 blocking preconditions** during `terraform plan`. Invalid configurations are rejected *before* any changes are applied.

### Blocking Preconditions (plan fails)

| Check | Error Message |
|-------|---------------|
| Team references undefined role | `undefined roles` |
| Team references undefined folder | `undefined folders` |
| Folder parent key doesn't exist | `undefined parent keys` |
| Invalid folder permission level | `invalid folder permission` (must be `View`, `Edit`, or `Admin`) |
| Folder name contains `/` | `must not contain` |
| Folder nested 3+ levels deep | `3rd level` |
| Team name exceeds 255 characters | `255-character limit` |
| Team has LBAC selectors but no datasources | `lbac_selectors but no datasources` |

Additional preconditions in `grafana_discovery.tf` validate API connectivity, response format, and detect ambiguous resource matches (e.g. duplicate team names in Grafana).

---

## CI/CD Pipelines

| Workflow | Trigger | What it does |
|----------|---------|--------------:|
| `terraform-plan.yml` | PR opened / updated | Validates YAML, runs `terraform plan` |
| `terraform-apply.yml` | Manual dispatch (type `APPLY`) | Runs `terraform plan` + `terraform apply` |
| `terraform-destroy.yml` | Manual dispatch (type `DESTROY`) | Runs `terraform destroy` |
| `team-onboarding.yml` | Manual dispatch (form) | Generates team config, auto-creates folder, opens PR |

### State Management

Terraform state is stored in the `terraform-state` orphan branch via the `.github/actions/tf-state` composite action.

### Required Repository Secrets

| Secret | Description |
|--------|-------------|
| `GRAFANA_URL` | Full URL of the Grafana instance |
| `GRAFANA_TOKEN` | Service account token with Admin permissions |

---

## Version Pinning

All tool and dependency versions are pinned to exact values to prevent unexpected breakage:

| Component | Version | File |
|-----------|---------|------|
| Terraform | `1.15.4` | `providers.tf`, all workflows |
| `grafana/grafana` provider | `4.23.0` | `providers.tf`, `.terraform.lock.hcl` |
| `hashicorp/http` provider | `3.5.0` | `providers.tf`, `.terraform.lock.hcl` |
| `actions/checkout` | `v4.2.2` (SHA pinned) | All workflows |
| `hashicorp/setup-terraform` | `v3.1.2` (SHA pinned) | Plan, Apply, Destroy workflows |
| `peter-evans/create-pull-request` | `v5.0.2` (SHA pinned) | Onboarding workflow |

**To upgrade**: Update the version in `providers.tf`, run `terraform init -upgrade` to regenerate `.terraform.lock.hcl`, then update the `terraform_version` in all workflow files.

> **Note on `auto_increment_version`**: The `grafana_role` resource emits a deprecation warning for `auto_increment_version`. This attribute is still required by provider v4.23.0 (one of `auto_increment_version` or `version` must be set). It can be safely removed when upgrading to a future provider version that lifts this constraint.

---

## Local Development

```bash
# Validate YAML syntax
yq e '.' config/folders.yaml
yq e '.' config/teams.yaml
yq e '.' config/roles.yaml

# Validate Terraform configuration
cd terraform
terraform init
terraform fmt -recursive
terraform validate

# Preview changes (read-only, safe to run anytime)
terraform plan

# Apply changes to Grafana
terraform apply
```

### Debugging Tips

- **Unexpected plan changes?** Check if Grafana UI edits conflict with Terraform-managed resources. Run `terraform plan` — the diff will show exactly which resource and attribute changed.
- **Role version drift?** Already mitigated by `ignore_changes = [version]`.
- **LBAC diff on every plan?** Selector lists are sorted before encoding. If drift persists, inspect the raw API response with: `curl -H "Authorization: Bearer $TF_VAR_grafana_token" "$TF_VAR_grafana_url/api/datasources/uid/<uid>/lbac/teams"`.
- **Folder deletion blocked?** `prevent_destroy_if_not_empty` — move dashboards first, then remove the folder from `folders.yaml`.
- **API discovery returning unexpected data?** The `api_pagination_limit` check block warns if any API response hits the 10,000 item limit.

---

## Variables Reference

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `grafana_url` | `string` | — (required) | URL of the Grafana instance |
| `grafana_token` | `string` (sensitive) | — (required) | Service account API token |
| `enable_external_groups` | `bool` | `false` | Enable Azure AD / LDAP group synchronisation |
| `prevent_destroy_if_not_empty` | `bool` | `true` | Block Terraform from destroying non-empty folders |
| `roles` | `map(object)` | `{}` | Fallback role definitions (normally loaded from `config/roles.yaml`) |
| `teams` | `map(object)` | `{}` | Fallback team config (normally loaded from `config/teams.yaml`) |
| `folders` | `map(object)` | `{}` | Fallback folder config (normally loaded from `config/folders.yaml`) |

---

## License

See [LICENSE](LICENSE) for details.
