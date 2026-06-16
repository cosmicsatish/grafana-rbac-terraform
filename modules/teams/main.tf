# Teams Module
# Creates teams, assigns roles, sets folder permissions, syncs external groups.

locals {
  grafana_base_url = trimsuffix(var.grafana_url, "/")

  # Flatten team → role pairs into a map keyed by "team/role"
  team_role_assignments = {
    for pair in flatten([
      for team_name, team_config in var.teams : [
        for role_name in try(team_config.roles, []) : {
          key      = "${team_name}/${role_name}"
          role_uid = var.role_uids[role_name]
          team_id  = grafana_team.all[team_name].id
        }
      ]
    ]) : pair.key => pair
  }

  # Flatten team → folder pairs into a map keyed by "team-folder"
  team_folder_permissions = {
    for record in flatten([
      for team_name, team_config in var.teams : [
        for folder_name, permission_level in try(team_config.folder_permissions, {}) : {
          # '/' separator matches grafana_discovery.tf — eliminates key-collision
          # risk when team or folder names contain hyphens.
          key        = "${team_name}/${folder_name}"
          team_id    = grafana_team.all[team_name].id
          folder_uid = var.folder_uids[folder_name]
          permission = permission_level
        }
        if contains(keys(var.folder_uids), folder_name)
      ]
    ]) : record.key => record
  }


  # Only include teams that have external group UIDs configured.
  configured_external_groups = {
    for team_name, team_config in var.teams :
    team_name => sort(distinct([
      for group_uid in team_config.external_group_uids :
      trimspace(group_uid) if trimspace(group_uid) != ""
    ]))
    if length(team_config.external_group_uids) > 0
  }
}

# ── Resources ─────────────────────────────────────────────────────────────────

resource "grafana_team" "all" {
  for_each = var.teams
  name     = each.key
  email    = try(each.value.email, null)

  # Membership is managed externally (AD / LDAP via grafana_team_external_group)
  # or manually in the Grafana UI. Terraform should not fight over it.
  ignore_externally_synced_members = true

  lifecycle {
    ignore_changes = [members]
  }
}

resource "grafana_role_assignment_item" "team_roles" {
  for_each   = local.team_role_assignments
  role_uid   = each.value.role_uid
  team_id    = each.value.team_id
  depends_on = [grafana_team.all]
}

resource "grafana_folder_permission_item" "team_access" {
  for_each   = local.team_folder_permissions
  folder_uid = each.value.folder_uid
  team       = each.value.team_id
  permission = each.value.permission
  depends_on = [grafana_team.all]
}

locals {
  merged_external_groups = {
    for team_name, configured_groups in local.configured_external_groups :
    team_name => sort(distinct(concat(
      try(var.existing_external_groups[team_name], []),
      configured_groups
    )))
  }
}

resource "grafana_team_external_group" "sync" {
  for_each   = var.enable_external_groups ? local.merged_external_groups : {}
  team_id    = grafana_team.all[each.key].id
  groups     = each.value
  depends_on = [grafana_team.all]

  lifecycle {
    create_before_destroy = true
  }
}

