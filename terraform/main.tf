# Grafana RBAC Configuration
# Modules: roles -> folders -> teams -> lbac

module "roles" {
  source = "../modules/roles"
  roles  = local.final_roles
}

module "folders" {
  source                       = "../modules/folders"
  folders                      = local.final_folders
  prevent_destroy_if_not_empty = var.prevent_destroy_if_not_empty
}

module "teams" {
  source = "../modules/teams"

  teams                    = local.final_teams
  role_uids                = module.roles.role_uids
  folder_uids              = module.folders.folder_uids
  enable_external_groups   = var.enable_external_groups
  existing_external_groups = local.parsed_existing_external_groups
  grafana_url              = var.grafana_url
  grafana_token            = var.grafana_token
}

module "lbac" {
  source = "../modules/lbac"

  teams           = local.final_teams
  datasource_uids = local.existing_datasource_uids

  # Merge pre-discovered UIDs/IDs with the live outputs from the teams resource.
  # This is the key to single-apply provisioning for brand-new teams:
  #   - local.existing_team_uids / existing_team_ids: populated from the HTTP
  #     discovery API at plan time (known for already-existing teams).
  #   - module.teams.team_uids / team_ids: produced by grafana_team.all after
  #     apply (known after creation for brand-new teams).
  # merge() gives precedence to the second map, so the live resource value
  # always wins — eliminating stale discovery data for recreated teams too.
  team_uids = merge(local.existing_team_uids, module.teams.team_uids)
  team_ids  = merge(local.existing_team_ids, module.teams.team_ids)

  existing_lbac_rules = local.parsed_existing_lbac_rules

  # Teams must exist before LBAC rules are applied.
  depends_on = [module.teams]
}

