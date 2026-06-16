# Validation Checks
#
# Use terraform_data preconditions instead of check blocks so invalid config
# blocks the plan/apply instead of only producing advisory diagnostics.

locals {


  # ── Role / folder references ───────────────────────────────────────────────

  invalid_role_references = distinct(flatten([
    for team_name, team_config in local.final_teams : [
      for role_name in try(team_config.roles, []) :
      "${team_name} -> ${role_name}"
      if try(local.final_roles[role_name], null) == null
    ]
  ]))

  invalid_folder_references = distinct(flatten([
    for team_name, team_config in local.final_teams : [
      for folder_name, permission in try(team_config.folder_permissions, {}) :
      "${team_name} -> ${folder_name}"
      if try(local.final_folders[folder_name], null) == null
    ]
  ]))

  invalid_folder_parent_references = distinct([
    for folder_name, folder_config in local.final_folders :
    "${folder_name} -> ${folder_config.parent_key}"
    if try(folder_config.parent_key, null) != null
    && try(local.final_folders[folder_config.parent_key], null) == null
  ])

  invalid_folder_permission_values = distinct(flatten([
    for team_name, team_config in local.final_teams : [
      for folder_name, permission in try(team_config.folder_permissions, {}) :
      "${team_name} -> ${folder_name} (invalid: ${permission})"
      if !contains(["View", "Edit", "Admin"], permission)
    ]
  ]))

  # ── Folder structure constraints ───────────────────────────────────────────

  # Folder names containing "/" break Grafana's path handling.
  folder_names_with_slashes = distinct([
    for folder_name in keys(local.final_folders) :
    folder_name
    if strcontains(folder_name, "/")
  ])

  # Only 2-level nesting is supported (root + one child). A grandchild folder
  # whose parent_key refers to another child folder would fail at the provider.
  over_nested_folders = distinct([
    for name, cfg in local.final_folders :
    "${name} (parent '${cfg.parent_key}' is itself a child folder)"
    if try(cfg.parent_key, null) != null
    && try(local.final_folders[cfg.parent_key].parent_key, null) != null
  ])

  # ── Team name constraints ──────────────────────────────────────────────────

  # Grafana enforces a 255-character hard limit on team names.
  teams_with_name_too_long = distinct([
    for team_name in keys(local.final_teams) :
    "${team_name} (${length(team_name)} chars)"
    if length(team_name) > 255
  ])

  # ── LBAC config constraints ────────────────────────────────────────────────

  # Teams that have lbac_selectors but no datasources listed will produce no
  # LBAC rules, which is almost certainly a config mistake.
  teams_with_selectors_but_no_datasources = distinct([
    for team_name, team_config in local.final_teams :
    team_name
    if length(try(team_config.lbac_selectors, [])) > 0 && length(try(team_config.datasources, [])) == 0
  ])

}

resource "terraform_data" "validate_config" {
  input = true

  lifecycle {
    precondition {
      condition     = length(local.invalid_role_references) == 0
      error_message = "Teams reference undefined roles: ${join(", ", local.invalid_role_references)}"
    }

    precondition {
      condition     = length(local.invalid_folder_references) == 0
      error_message = "Teams reference undefined folders: ${join(", ", local.invalid_folder_references)}"
    }

    precondition {
      condition     = length(local.invalid_folder_parent_references) == 0
      error_message = "Folders reference undefined parent keys: ${join(", ", local.invalid_folder_parent_references)}"
    }

    precondition {
      condition     = length(local.invalid_folder_permission_values) == 0
      error_message = "Teams have invalid folder permission levels (must be View, Edit, or Admin): ${join(", ", local.invalid_folder_permission_values)}"
    }

    precondition {
      condition     = length(local.folder_names_with_slashes) == 0
      error_message = "Folder names must not contain '/': ${join(", ", local.folder_names_with_slashes)}"
    }

    precondition {
      condition     = length(local.over_nested_folders) == 0
      error_message = "Only 2-level folder hierarchy is supported (root + one child). These entries would require a 3rd level: ${join(", ", local.over_nested_folders)}"
    }

    precondition {
      condition     = length(local.teams_with_name_too_long) == 0
      error_message = "Team names exceed Grafana's 255-character limit: ${join(", ", local.teams_with_name_too_long)}"
    }

    precondition {
      condition     = length(local.teams_with_selectors_but_no_datasources) == 0
      error_message = "Teams have lbac_selectors but no datasources listed (rules will be silently dropped): ${join(", ", local.teams_with_selectors_but_no_datasources)}"
    }
  }
}
