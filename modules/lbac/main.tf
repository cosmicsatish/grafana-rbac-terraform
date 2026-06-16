# LBAC Module
# Configures Label-Based Access Control for each LBAC-enabled datasource.
#
# MERGE STRATEGY (preserves other teams' rules):
#   1. Start with the full existing rules map from Grafana (all teams, not just ours).
#   2. Overlay only the rules for teams declared in this repo.
#   3. Write the merged result back atomically (Grafana's API is per-datasource PUT).
#
# This means:
#   - Teams NOT in this repo keep their existing selectors unchanged.
#   - Teams IN this repo get their selectors set to exactly what is in YAML.
#   - Adding/changing one team's selectors does NOT disturb other teams.
#
# SINGLE-APPLY for new teams:
#   var.team_uids is the MERGED map of (discovery UIDs ∪ live resource UIDs).
#   Brand-new teams are absent from discovery but present in module.teams.team_uids
#   after apply, so their rules are provisioned in the same apply as team creation.

locals {
  # All datasources referenced for LBAC that actually exist in Grafana.
  all_datasources = toset([
    for ds in distinct(flatten([
      for team_config in var.teams :
      try(team_config.datasources, [])
      if length(try(team_config.lbac_selectors, [])) > 0
    ])) : ds
    if contains(keys(var.datasource_uids), ds)
  ])

  # Map: datasource → { team_uid → sorted([selectors]) }
  # Only teams whose UID is known (either from discovery or freshly created)
  # and that have LBAC selectors declared for this datasource are included.
  rules_by_datasource = {
    for ds in local.all_datasources : ds => {
      for team_name, team_config in var.teams :
      var.team_uids[team_name] => sort(distinct(team_config.lbac_selectors))
      if contains(try(team_config.datasources, []), ds)
      && length(try(team_config.lbac_selectors, [])) > 0
      && contains(keys(var.team_uids), team_name)
    }
  }

  # Merged rules per datasource:
  #   - Start from the existing Grafana state (all teams, including unmanaged ones).
  #   - Overlay our declared teams on top — existing selectors for each managed
  #     team UID are replaced; other team UIDs are left untouched.
  # Sort each team's selector list for stable JSON encoding (no spurious diffs).
  merged_rules = {
    for ds in local.all_datasources : ds => {
      for team_uid, selectors in merge(
        try(var.existing_lbac_rules[ds], {}),
        local.rules_by_datasource[ds]
      ) :
      team_uid => sort(distinct(selectors))
    }
  }
}

# ── Write back merged rules ────────────────────────────────────────────────────
# One resource per datasource (API constraint: PUT replaces all rules atomically).
# Plan diffs are readable at the team-UID key level within the JSON — each team
# entry is a distinct map key, so Terraform shows exactly which team changed.

resource "grafana_data_source_config_lbac_rules" "lbac" {
  for_each       = local.all_datasources
  datasource_uid = var.datasource_uids[each.key]
  rules          = jsonencode(local.merged_rules[each.key])
}

# ── Datasource Query Permissions ──────────────────────────────────────────────
# One permission item per team+datasource pair.
# Only teams whose ID is known (discovery or live resource) are included.

locals {
  team_datasource_permissions = {
    for pair in flatten([
      for team_name, team_config in var.teams : [
        for ds in try(team_config.datasources, []) : {
          key            = "${team_name}/${ds}"
          team_id        = var.team_ids[team_name]
          datasource_uid = var.datasource_uids[ds]
        }
        if contains(keys(var.team_ids), team_name)
        && contains(keys(var.datasource_uids), ds)
      ]
    ]) : pair.key => pair
  }
}

resource "grafana_data_source_permission_item" "team_query" {
  for_each       = local.team_datasource_permissions
  datasource_uid = each.value.datasource_uid
  team           = each.value.team_id
  permission     = "Query"
}
