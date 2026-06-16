variable "grafana_url" {
  description = "URL of the Grafana instance (e.g. https://grafana.example.com)"
  type        = string
}

variable "grafana_token" {
  description = "Service account API token for Grafana authentication"
  type        = string
  sensitive   = true
}

# ── Primary configuration is YAML-driven (see config/) ───────────────────────
# These variables act as bare fallbacks when the corresponding YAML file is absent.

variable "roles" {
  description = "Custom RBAC role definitions. Normally loaded from config/roles.yaml."
  type = map(object({
    description = string
    permissions = map(string)
  }))
  default = {}
}

variable "teams" {
  description = "Team configuration fallback when config/teams.yaml is absent. Normally leave this empty and use the teams YAML."
  type = map(object({
    email               = optional(string)
    roles               = optional(list(string), [])
    folder_permissions  = optional(map(string), {})
    external_group_uids = optional(list(string), [])
    lbac_selectors      = optional(list(string), [])
    datasources         = optional(list(string), [])
  }))
  default = {}
}

variable "folders" {
  description = "Folder structure. Normally loaded from config/folders.yaml."
  type = map(object({
    description = optional(string)
    parent_key  = optional(string)
    parent_uid  = optional(string) # Backward-compatible alias for parent_key.
  }))
  default = {}
}

variable "enable_external_groups" {
  description = "Enable external group synchronisation (Azure AD / LDAP)"
  type        = bool
  default     = false
}

variable "prevent_destroy_if_not_empty" {
  description = "Prevent Terraform from destroying folders that contain dashboards or other folders"
  type        = bool
  default     = true
}
