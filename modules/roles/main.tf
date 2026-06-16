# Custom Roles Module
# Creates roles with permissions from direct actions or inherited from fixed/plugin roles.

locals {
  # Collect every fixed:/plugins: role name referenced across all role configs.
  # These are Grafana built-in roles whose permissions we'll inherit.
  builtin_role_names = toset(flatten([
    for role_name, role_config in var.roles : [
      for permission_name, scope in try(role_config.permissions, {}) :
      permission_name
      if startswith(permission_name, "fixed:") || startswith(permission_name, "plugins:")
    ]
  ]))

  # Certain scopes produced by fixed role expansion are invalid in custom roles.
  invalid_scope_patterns = [
    "receivers:type:",
    "receivers:uid:",
    "routingtrees:",
    "inhibition-rules:"
  ]
}

# Look up the full permission set of each referenced built-in role.
data "grafana_role" "builtin" {
  for_each = local.builtin_role_names
  name     = each.value
}

locals {
  # 1. Expand all permissions for each custom role configuration.
  # We construct a flat list of objects representing each raw permission block.
  expanded_permissions = flatten([
    for role_name, role_config in var.roles : [
      for permission_name, custom_scope in try(role_config.permissions, {}) :
      startswith(permission_name, "fixed:") || startswith(permission_name, "plugins:") ? [
        for perm in data.grafana_role.builtin[permission_name].permissions : {
          role_name = role_name
          action    = perm.action
          resolved_scope = (
            # If custom_scope is empty or original permission is global/unscoped, keep original scope
            custom_scope == "" || perm.scope == "" ? perm.scope : (
              # Datasource scope overrides only datasource permissions
              startswith(custom_scope, "datasources:") ? (
                startswith(perm.scope, "datasources:") ? custom_scope : perm.scope
              ) :
              # Folder/Dashboard scope overrides folder, dashboard, or alerting permissions
              startswith(custom_scope, "folders:") || startswith(custom_scope, "dashboards:") ? (
                startswith(perm.scope, "folders:") || startswith(perm.scope, "dashboards:") || startswith(perm.scope, "alert.rules:") || startswith(perm.action, "dashboards:") || startswith(perm.action, "folders:") || startswith(perm.action, "alerting:") ? custom_scope : perm.scope
              ) :
              # Other scopes (e.g. segments:*) override as fallback
              custom_scope
            )
          )
        }
        ] : [
        # Direct permission (already resolved)
        {
          role_name      = role_name
          action         = permission_name
          resolved_scope = custom_scope
        }
      ]
    ]
  ])

  # 2. Filter, deduplicate, and organize permissions by custom role name.
  role_permissions = {
    for role_name in keys(var.roles) : role_name => toset([
      for perm in local.expanded_permissions : {
        action = perm.action
        scope  = perm.resolved_scope
      }
      if perm.role_name == role_name
      && !anytrue([
        for pattern in local.invalid_scope_patterns :
        strcontains(perm.resolved_scope, pattern)
      ])
    ])
  }
}

resource "grafana_role" "custom" {
  for_each = var.roles

  name        = each.key
  description = each.value.description

  # Required by provider v4.23.0 (one of auto_increment_version|version must be set).
  # Deprecated upstream — remove when upgrading to a provider version that lifts the constraint.
  auto_increment_version = true

  dynamic "permissions" {
    for_each = local.role_permissions[each.key]
    content {
      action = permissions.value.action
      scope  = permissions.value.scope
    }
  }

  # Grafana manages the version counter server-side; ignore_changes prevents
  # phantom diffs on every plan even when role content is identical.
  lifecycle {
    ignore_changes = [version]
  }
}

