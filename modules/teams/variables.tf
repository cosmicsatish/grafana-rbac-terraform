variable "teams" {
  description = "Teams configuration"
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

variable "role_uids" {
  description = "Map of role names to role UIDs"
  type        = map(string)
  default     = {}
}

variable "folder_uids" {
  description = "Map of folder names to folder UIDs"
  type        = map(string)
  default     = {}
}

variable "enable_external_groups" {
  description = "Enable external group synchronization (can be disabled if API has issues)"
  type        = bool
  default     = true
}

variable "grafana_url" {
  description = "Grafana instance URL, used to preserve existing external group sync entries"
  type        = string
}

variable "grafana_token" {
  description = "Grafana service account token, used to preserve existing external group sync entries"
  type        = string
  sensitive   = true
}

variable "existing_external_groups" {
  description = "Existing external group mappings from Grafana, queried at plan time in root (map: team_name -> list of group_uids)"
  type        = any
  default     = {}
}
