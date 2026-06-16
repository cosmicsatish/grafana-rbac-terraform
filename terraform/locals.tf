locals {
  # ── Config file paths ──────────────────────────────────────────────────────
  roles_config_path   = "${path.module}/../config/roles.yaml"
  folders_config_path = "${path.module}/../config/folders.yaml"
  catalog_config_path = "${path.module}/../config/teams.yaml"

  # ── Raw YAML loads ─────────────────────────────────────────────────────────
  raw_roles   = try(yamldecode(fileexists(local.roles_config_path) ? file(local.roles_config_path) : jsonencode(var.roles)), {})
  raw_folders = try(yamldecode(fileexists(local.folders_config_path) ? file(local.folders_config_path) : jsonencode(var.folders)), {})
  raw_catalog = try(yamldecode(fileexists(local.catalog_config_path) ? file(local.catalog_config_path) : "teams: {}\n"), {})

  # ── Team catalog ───────────────────────────────────────────────────────────
  catalog_teams = try(local.raw_catalog.teams, {})

  # Extract default roles (roles where default: true is defined)
  default_roles = [
    for role_name, role_config in local.raw_roles : role_name
    if try(role_config.default, false) == true
  ]

  # Extract roles auto-assigned to folder owners (roles where auto_assign_to_folder_owner: true is defined)
  folder_owner_roles = [
    for role_name, role_config in local.raw_roles : role_name
    if try(role_config.auto_assign_to_folder_owner, false) == true
  ]

  # Extract default folder permissions (folders where default_permissions.all_teams is defined)
  default_folder_permissions = {
    for folder_name, folder_config in local.raw_folders : folder_name => folder_config.default_permissions.all_teams
    if try(folder_config.default_permissions.all_teams, null) != null
  }

  # Extract global defaults from catalog config
  default_owner_folder_permission = try(local.raw_catalog.defaults.owner_folder_permission, "Admin")
  default_datasources             = try(local.raw_catalog.defaults.datasources, ["loki-lbac"])
  default_lbac_selectors          = try(local.raw_catalog.defaults.lbac_selectors, ["{ business_unit!~\"reset|trioptima|osttra\" }"])

  # Expand and normalize catalog entries.
  expanded_catalog_teams = {
    for team_name, team_config in local.catalog_teams : team_name => {
      email = try(team_config.email, null)

      roles = concat(
        local.default_roles,
        try(team_config.folder, null) != null ? local.folder_owner_roles : [],
        try(team_config.roles, [])
      )

      folder_permissions = tomap(merge(
        local.default_folder_permissions,
        try({ tostring(team_config.folder) = local.default_owner_folder_permission }, {}),
        try(team_config.folder_permissions, {})
      ))

      external_group_uids = concat(
        try(team_config.external_group_uids, []),
        try([team_config.group_uid], [])
      )

      lbac_selectors = try(
        team_config.lbac,
        team_config.lbac_selectors,
        length(try(team_config.datasources, local.default_datasources)) > 0 ? local.default_lbac_selectors : []
      )

      datasources = try(team_config.datasources, local.default_datasources)
    }
  }

  # ── Final normalised structs ───────────────────────────────────────────────
  # catalog_teams is the primary source; var.teams is a bare tfvar fallback.
  _raw_team_config = yamldecode(length(local.catalog_teams) > 0 ? yamlencode(local.expanded_catalog_teams) : yamlencode(var.teams))

  final_roles = local.raw_roles

  final_folders = {
    for folder_name, folder_config in local.raw_folders : folder_name => {
      description = try(folder_config.description, null)
      parent_key  = try(folder_config.parent_key, try(folder_config.parent_uid, null))
    }
  }

  final_teams = {
    for team_name, team_config in local._raw_team_config : team_name => {
      email = try(team_config.email, null)
      roles = distinct([
        for role_name in try(team_config.roles, []) :
        trimspace(tostring(role_name))
        if trimspace(tostring(role_name)) != ""
      ])
      folder_permissions = try(team_config.folder_permissions, {})
      external_group_uids = distinct([
        for group_uid in try(team_config.external_group_uids, []) :
        trimspace(tostring(group_uid))
        if trimspace(tostring(group_uid)) != ""
      ])
      lbac_selectors = distinct([
        for selector in try(team_config.lbac_selectors, []) :
        trimspace(tostring(selector))
        if trimspace(tostring(selector)) != ""
      ])
      datasources = distinct([
        for datasource_name in try(team_config.datasources, []) :
        trimspace(tostring(datasource_name))
        if trimspace(tostring(datasource_name)) != ""
      ])
    }
  }
}
