variable "teams" {
  description = "Teams configuration with LBAC selectors"
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

variable "team_ids" {
  description = "Map of team names to team IDs (for datasource permissions)"
  type        = map(string)
  default     = {}
}

variable "team_uids" {
  description = "Map of team names to team UIDs (for LBAC rules)"
  type        = map(string)
  default     = {}
}

variable "datasource_uids" {
  description = <<-EOT
    Map of datasource names to UIDs, sourced from grafana_discovery.
    Only datasources present in this map will have LBAC rules applied.
    Datasources configured in YAML but absent from this map are silently
    skipped — a check block in grafana_discovery.tf produces an advisory
    warning in that case.
  EOT
  type        = map(string)
  default     = {}
}

variable "existing_lbac_rules" {
  description = "Existing LBAC rules from Grafana datasources, queried at plan time in root (map: datasource → team_uid → selectors)"
  type        = any
  default     = {}
}
