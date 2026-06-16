# grafana_discovery.tf
# ─────────────────────────────────────────────────────────────────────────────
# Queries the live Grafana API to discover which declared resources already
# exist, then imports them into Terraform state automatically.
#
# HOW IT WORKS
#   1. data "http" blocks call the Grafana REST API at plan time.
#   2. Locals parse the JSON and build name→id maps for resources that exist in
#      BOTH Grafana AND our YAML config (so only managed resources are touched).
#   3. import blocks iterate those maps and import each resource that is not yet
#      in state. On subsequent runs these are silent no-ops.
#
# NET EFFECT: running `terraform plan` is now self-contained — no pre-import
# script, no Makefile target, no manual steps.
# ─────────────────────────────────────────────────────────────────────────────

# ── Live Grafana API lookups ──────────────────────────────────────────────────

data "http" "grafana_teams" {
  url = "${trimsuffix(var.grafana_url, "/")}/api/teams/search?limit=10000"
  request_headers = {
    Authorization = "Bearer ${var.grafana_token}"
  }
  retry {
    attempts     = 4
    min_delay_ms = 500
    max_delay_ms = 15000
  }
}

data "http" "grafana_folders" {
  url = "${trimsuffix(var.grafana_url, "/")}/api/folders?limit=10000"
  request_headers = {
    Authorization = "Bearer ${var.grafana_token}"
  }
  retry {
    attempts     = 4
    min_delay_ms = 500
    max_delay_ms = 15000
  }
}

data "http" "grafana_roles" {
  url = "${trimsuffix(var.grafana_url, "/")}/api/access-control/roles?limit=10000"
  request_headers = {
    Authorization = "Bearer ${var.grafana_token}"
  }
  retry {
    attempts     = 4
    min_delay_ms = 500
    max_delay_ms = 15000
  }
}

data "http" "grafana_datasources" {
  url = "${trimsuffix(var.grafana_url, "/")}/api/datasources"
  request_headers = {
    Authorization = "Bearer ${var.grafana_token}"
  }
  retry {
    attempts     = 4
    min_delay_ms = 500
    max_delay_ms = 15000
  }
}

# ── Parsed lookups ────────────────────────────────────────────────────────────

locals {
  discovery_http_errors = [
    for api, code in {
      teams       = data.http.grafana_teams.status_code
      folders     = data.http.grafana_folders.status_code
      roles       = data.http.grafana_roles.status_code
      datasources = data.http.grafana_datasources.status_code
    } : "${api} API returned HTTP ${code}" if code != 200
  ]

  discovery_json_errors = [
    for api, valid in {
      teams       = can(tolist(jsondecode(data.http.grafana_teams.response_body).teams))
      folders     = can(tolist(jsondecode(data.http.grafana_folders.response_body)))
      roles       = can(tolist(jsondecode(data.http.grafana_roles.response_body)))
      datasources = can(jsondecode(data.http.grafana_datasources.response_body))
    } : "${api} API response is invalid or malformed JSON" if !valid
  ]


  # ── Teams ──────────────────────────────────────────────────────────────────
  _raw_teams = try(tolist(jsondecode(data.http.grafana_teams.response_body).teams), [])

  _managed_team_matches = {
    for t in local._raw_teams :
    tostring(try(t.name, "")) => t...
    if contains(keys(local.final_teams), tostring(try(t.name, "")))
  }

  duplicate_existing_team_names = [
    for team_name, matches in local._managed_team_matches :
    team_name
    if length(matches) > 1
  ]

  # name → string(id) — only for teams declared in our YAML config.
  existing_team_ids = {
    for team_name, matches in local._managed_team_matches :
    team_name => tostring(matches[0].id)
    if length(matches) == 1
  }

  # name → uid string — used for LBAC rules so keys are always known at plan time.
  # Teams not yet in Grafana are absent here; their LBAC rules are added on the
  # next plan after the team is created (two-step rollout for brand-new teams).
  existing_team_uids = {
    for team_name, matches in local._managed_team_matches :
    team_name => tostring(matches[0].uid)
    if length(matches) == 1
  }

  # ── Folders ────────────────────────────────────────────────────────────────
  _raw_folders = try(tolist(jsondecode(data.http.grafana_folders.response_body)), [])

  # Root folders: declared in config with no parent_key.
  _config_root_folders = toset([
    for name, cfg in local.final_folders : name
    if try(cfg.parent_key, null) == null
  ])

  # Child folders: declared in config with a parent_key.
  _config_child_folders = {
    for name, cfg in local.final_folders : name => cfg.parent_key
    if try(cfg.parent_key, null) != null
  }

  _managed_root_folder_matches = {
    for f in local._raw_folders :
    tostring(try(f.title, "")) => f...
    if contains(local._config_root_folders, tostring(try(f.title, "")))
    && try(f.parentUid, "") == ""
  }

  duplicate_existing_root_folder_titles = [
    for title, matches in local._managed_root_folder_matches :
    title
    if length(matches) > 1
  ]

  # title → uid  for root folders that already exist in Grafana
  existing_root_folder_uids = {
    for title, matches in local._managed_root_folder_matches :
    title => matches[0].uid
    if length(matches) == 1
  }

  _managed_child_folder_matches = {
    for folder_name, parent_key in local._config_child_folders :
    folder_name => [
      for f in local._raw_folders : f
      if tostring(try(f.title, "")) == folder_name
      && try(f.parentUid, "") == try(local.existing_root_folder_uids[parent_key], "__parent_not_imported__")
    ]
  }

  duplicate_existing_child_folder_titles = [
    for title, matches in local._managed_child_folder_matches :
    title
    if length(matches) > 1
  ]

  # title → uid  for child folders that already exist in Grafana
  existing_child_folder_uids = {
    for title, matches in local._managed_child_folder_matches :
    title => matches[0].uid
    if length(matches) == 1
  }

  # ── Custom roles ───────────────────────────────────────────────────────────
  _raw_roles = try(tolist(jsondecode(data.http.grafana_roles.response_body)), [])

  _managed_role_matches = {
    for r in local._raw_roles :
    tostring(try(r.name, "")) => r...
    if contains(keys(local.final_roles), tostring(try(r.name, "")))
    && !startswith(tostring(try(r.uid, "")), "fixed:")
    && !startswith(tostring(try(r.uid, "")), "basic:")
  }

  duplicate_existing_role_names = [
    for role_name, matches in local._managed_role_matches :
    role_name
    if length(matches) > 1
  ]

  # name → uid  — only custom roles declared in our YAML (not fixed: built-ins)
  existing_role_uids = {
    for role_name, matches in local._managed_role_matches :
    role_name => matches[0].uid
    if length(matches) == 1
  }

  # The /api/datasources endpoint returns different shapes across Grafana versions:
  #   Shape A: [{...}, {...}]        — bare array (most common)
  #   Shape B: {"datasources":[...]} — wrapped object (some cloud/ent editions)
  # We cannot use tolist() because datasource jsonData schemas are heterogeneous;
  # [for...if can(ds.name)] iterates safely without type constraints.
  _datasource_json = try(jsondecode(data.http.grafana_datasources.response_body), null)

  _raw_datasources = try(
    can(local._datasource_json.datasources) ? [
      for ds in local._datasource_json.datasources : ds if can(ds.name)
      ] : [
      for ds in local._datasource_json : ds if can(ds.name)
    ],
    []
  )


  # name → uid  — datasources referenced in any team's lbac config
  _lbac_datasource_names = toset(flatten([
    for tc in values(local.final_teams) :
    try(tc.datasources, [])
    if length(try(tc.lbac_selectors, [])) > 0
  ]))

  _managed_datasource_matches = {
    for ds in local._raw_datasources :
    tostring(try(ds.name, "")) => ds...
    if contains(local._lbac_datasource_names, tostring(try(ds.name, "")))
  }

  duplicate_existing_datasource_names = [
    for datasource_name, matches in local._managed_datasource_matches :
    datasource_name
    if length(matches) > 1
  ]

  existing_datasource_uids = {
    for datasource_name, matches in local._managed_datasource_matches :
    datasource_name => matches[0].uid
    if length(matches) == 1
  }

  # Datasources configured for LBAC in YAML but absent from Grafana.
  # The LBAC module silently skips these; the check block below warns you.
  _missing_lbac_datasources = setsubtract(
    local._lbac_datasource_names,
    toset(keys(local.existing_datasource_uids))
  )

  # Non-empty when an API response hit the page limit — discovery may be
  # incomplete. The check block below surfaces this as an advisory warning.
  _api_responses_at_limit = [
    for api, len in {
      teams   = length(local._raw_teams)
      folders = length(local._raw_folders)
      roles   = length(local._raw_roles)
    } : "${api} API returned ${len} results — increase ?limit" if len >= 10000
  ]

  # ── Role assignments (team → role cross-product) ───────────────────────────
  # Only import assignments where BOTH the team AND the role already exist.
  existing_role_assignments = {
    for pair in flatten([
      for team_name, tc in local.final_teams : [
        for role_name in try(tc.roles, []) : {
          key      = "${team_name}/${role_name}"
          role_uid = try(local.existing_role_uids[role_name], "")
          team_id  = try(local.existing_team_ids[team_name], "")
        }
        if try(local.existing_role_uids[role_name], null) != null
        && try(local.existing_team_ids[team_name], null) != null
      ]
    ]) : pair.key => pair
  }

  # ── Folder permission items ────────────────────────────────────────────────
  _all_folder_uids = merge(
    local.existing_root_folder_uids,
    local.existing_child_folder_uids
  )

  existing_folder_permissions = {
    for record in flatten([
      for team_name, tc in local.final_teams : [
        for folder_name, perm in try(tc.folder_permissions, {}) : {
          # Use '/' separator — safe because folder names with '/' are rejected
          # by validations.tf, eliminating any key-collision risk.
          key        = "${team_name}/${folder_name}"
          folder_uid = try(local._all_folder_uids[folder_name], "")
          team_id    = try(local.existing_team_ids[team_name], "")
        }
        if try(local._all_folder_uids[folder_name], null) != null
        && try(local.existing_team_ids[team_name], null) != null
      ]
    ]) : record.key => record
  }

  # ── External group sync ────────────────────────────────────────────────────
  existing_external_groups = {
    for team_name, tc in local.final_teams :
    team_name => local.existing_team_ids[team_name]
    if var.enable_external_groups
    && length(try(tc.external_group_uids, [])) > 0
    && try(local.existing_team_ids[team_name], null) != null
  }

  ambiguous_discovery_matches = [
    for type, dups in {
      "team names"          = local.duplicate_existing_team_names
      "root folder titles"  = local.duplicate_existing_root_folder_titles
      "child folder titles" = local.duplicate_existing_child_folder_titles
      "custom role names"   = local.duplicate_existing_role_names
      "datasource names"    = local.duplicate_existing_datasource_names
    } : "duplicate existing ${type}: ${join(", ", dups)}" if length(dups) > 0
  ]
}

resource "terraform_data" "validate_grafana_discovery" {
  input = true

  lifecycle {
    precondition {
      condition     = length(local.discovery_http_errors) == 0
      error_message = "Grafana discovery API calls failed: ${join("; ", local.discovery_http_errors)}"
    }

    precondition {
      condition     = length(local.discovery_json_errors) == 0
      error_message = "Grafana discovery API responses were unexpected: ${join("; ", local.discovery_json_errors)}"
    }

    precondition {
      condition     = length(local.ambiguous_discovery_matches) == 0
      error_message = "Grafana discovery found ambiguous existing resources for declared config: ${join("; ", local.ambiguous_discovery_matches)}"
    }
  }
}

# ── Import blocks ─────────────────────────────────────────────────────────────
# Each block is a no-op when the resource is already in state.
# Resources absent from Grafana are also absent from the maps, so they are
# created fresh by the next terraform apply.

import {
  for_each = local.existing_role_uids
  to       = module.roles.grafana_role.custom[each.key]
  id       = each.value
}

import {
  for_each = local.existing_root_folder_uids
  to       = module.folders.grafana_folder.root[each.key]
  id       = each.value
}

import {
  for_each = local.existing_child_folder_uids
  to       = module.folders.grafana_folder.child[each.key]
  id       = each.value
}

import {
  for_each = local.existing_team_ids
  to       = module.teams.grafana_team.all[each.key]
  id       = each.value
}

import {
  for_each = local.existing_role_assignments
  to       = module.teams.grafana_role_assignment_item.team_roles[each.key]
  id       = "${each.value.role_uid}:team:${each.value.team_id}"
}

import {
  for_each = local.existing_folder_permissions
  to       = module.teams.grafana_folder_permission_item.team_access[each.key]
  id       = "${each.value.folder_uid}:team:${each.value.team_id}"
}

import {
  for_each = local.existing_external_groups
  to       = module.teams.grafana_team_external_group.sync[each.key]
  id       = each.value
}

import {
  for_each = local.existing_datasource_uids
  to       = module.lbac.grafana_data_source_config_lbac_rules.lbac[each.key]
  id       = each.value
}

import {
  for_each = local.existing_datasource_permissions
  to       = module.lbac.grafana_data_source_permission_item.team_query[each.key]
  id       = "${each.value.datasource_uid}:team:${each.value.team_id}"
}

# ── Advisory checks (non-blocking — warn but do not abort) ────────────────────
# 'check' blocks require Terraform >= 1.5 (root providers.tf requires >= 1.7).

check "lbac_datasources_exist" {
  assert {
    condition     = length(local._missing_lbac_datasources) == 0
    error_message = "Datasources referenced for LBAC are not (yet) present in Grafana — their rules will be skipped until the datasource is created: ${join(", ", local._missing_lbac_datasources)}"
  }
}

check "api_pagination_limit" {
  assert {
    condition     = length(local._api_responses_at_limit) == 0
    error_message = "Some Grafana API responses hit the page limit — discovery may be incomplete and some resources could be re-created instead of imported: ${join("; ", local._api_responses_at_limit)}"
  }
}

# ── LBAC Discovery ────────────────────────────────────────────────────────────

locals {
  existing_lbac_datasources = [
    for ds in local._lbac_datasource_names : ds
    if contains(keys(local.existing_datasource_uids), ds)
  ]
}

data "http" "existing_lbac_rules" {
  for_each = toset(local.existing_lbac_datasources)

  url = "${trimsuffix(var.grafana_url, "/")}/api/datasources/uid/${local.existing_datasource_uids[each.key]}/lbac/teams"

  request_headers = {
    Authorization = "Bearer ${var.grafana_token}"
    Content-Type  = "application/json"
  }

  retry {
    attempts     = 4
    min_delay_ms = 500
    max_delay_ms = 15000
  }
}

data "http" "datasource_permissions" {
  for_each = toset(local.existing_lbac_datasources)

  url = "${trimsuffix(var.grafana_url, "/")}/api/access-control/datasources/${local.existing_datasource_uids[each.key]}"

  request_headers = {
    Authorization = "Bearer ${var.grafana_token}"
    Content-Type  = "application/json"
  }

  retry {
    attempts     = 4
    min_delay_ms = 500
    max_delay_ms = 15000
  }
}

resource "terraform_data" "validate_lbac_reads" {
  for_each = toset(local.existing_lbac_datasources)

  input = each.key

  lifecycle {
    precondition {
      condition     = contains([200, 404], data.http.existing_lbac_rules[each.key].status_code)
      error_message = "Grafana LBAC lookup failed for datasource '${each.key}': HTTP ${data.http.existing_lbac_rules[each.key].status_code}. Ensure LBAC is enabled on this datasource and the service account has the required permissions."
    }

    precondition {
      condition     = data.http.existing_lbac_rules[each.key].status_code != 200 || can(jsondecode(data.http.existing_lbac_rules[each.key].response_body))
      error_message = "Grafana LBAC lookup returned invalid JSON for datasource '${each.key}'"
    }
  }
}

locals {
  _raw_existing_lbac_rules = {
    for ds in local.existing_lbac_datasources :
    ds => data.http.existing_lbac_rules[ds].status_code == 200 ? try(jsondecode(data.http.existing_lbac_rules[ds].response_body), {}) : {}
  }

  # Parse the LBAC API response into a uniform map: team_uid → [selectors].
  # The API may return rules in multiple shapes:
  #   Shape D: {"rules": [{"teamUID": "...", "rules": [...]}]}  (current Grafana LBAC API)
  #   Shape A: [{"teamUID": "...", "rules": [...]}]             (list variant)
  #   Shape B/C: {"<teamUID>": [...]}                           (direct map, legacy)
  parsed_existing_lbac_rules = {
    for ds in local.existing_lbac_datasources : ds => try(
      # Shape D: wrapped object with "rules" list
      {
        for entry in tolist(local._raw_existing_lbac_rules[ds].rules) :
        tostring(try(entry.teamUID, entry.team_uid, entry.teamUid, entry.uid)) => try(entry.rules, entry.selectors, [])
      },
      # Shape A: bare list of rule objects
      {
        for entry in tolist(local._raw_existing_lbac_rules[ds]) :
        tostring(try(entry.teamUID, entry.team_uid, entry.teamUid, entry.uid)) => try(entry.rules, entry.selectors, [])
      },
      # Shape B/C: direct map
      local._raw_existing_lbac_rules[ds]
    )
  }

  # ── Datasource Permissions Discovery ─────────────────────────────────────────

  _raw_datasource_permissions = {
    for ds in local.existing_lbac_datasources :
    ds => try(jsondecode(data.http.datasource_permissions[ds].response_body), [])
  }

  team_id_to_name = {
    for name, id in local.existing_team_ids : id => name
  }

  existing_datasource_permissions = {
    for record in flatten([
      for ds in local.existing_lbac_datasources : [
        for perm in local._raw_datasource_permissions[ds] : {
          key            = "${local.team_id_to_name[tostring(perm.teamId)]}/${ds}"
          team_id        = tostring(perm.teamId)
          datasource_uid = local.existing_datasource_uids[ds]
        }
        if try(perm.teamId, null) != null
        && contains(keys(local.team_id_to_name), tostring(perm.teamId))
      ]
    ]) : record.key => record
  }
}

# ── External Groups Discovery ──────────────────────────────────────────────────

locals {
  existing_teams_with_external_groups = [
    for team_name, team_config in local.final_teams : team_name
    if var.enable_external_groups
    && length(try(team_config.external_group_uids, [])) > 0
    && contains(keys(local.existing_team_ids), team_name)
  ]
}

data "http" "existing_external_groups" {
  for_each = toset(local.existing_teams_with_external_groups)

  url = "${trimsuffix(var.grafana_url, "/")}/api/teams/${local.existing_team_ids[each.key]}/groups"

  request_headers = {
    Authorization = "Bearer ${var.grafana_token}"
    Content-Type  = "application/json"
  }

  retry {
    attempts     = 4
    min_delay_ms = 500
    max_delay_ms = 15000
  }
}

resource "terraform_data" "validate_external_group_reads" {
  for_each = toset(local.existing_teams_with_external_groups)

  input = each.key

  lifecycle {
    precondition {
      condition     = data.http.existing_external_groups[each.key].status_code == 200
      error_message = "Grafana external group lookup failed for team ${each.key}: HTTP ${data.http.existing_external_groups[each.key].status_code}"
    }

    precondition {
      condition     = can(jsondecode(data.http.existing_external_groups[each.key].response_body))
      error_message = "Grafana external group lookup returned invalid JSON for team ${each.key}"
    }
  }
}

locals {
  _raw_existing_external_groups = {
    for team_name in local.existing_teams_with_external_groups :
    team_name => try(jsondecode(data.http.existing_external_groups[team_name].response_body), [])
  }

  _existing_external_group_lists = {
    for team_name, raw_groups in local._raw_existing_external_groups :
    team_name => try(tolist(raw_groups), raw_groups.groups, raw_groups.groupIds, raw_groups.group_ids, [])
  }

  parsed_existing_external_groups = {
    for team_name in local.existing_teams_with_external_groups :
    team_name => distinct(compact([
      for group in local._existing_external_group_lists[team_name] :
      trimspace(tostring(try(group.groupId, group.group_id, group.groupUid, group.groupUID, group.uid, group, "")))
    ]))
  }
}
