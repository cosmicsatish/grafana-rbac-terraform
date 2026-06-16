variable "folders" {
  description = "Folders configuration with support for nested hierarchy"
  type = map(object({
    description = optional(string)
    parent_key  = optional(string)
  }))
  default = {}
}

variable "prevent_destroy_if_not_empty" {
  description = "Prevent Terraform from destroying folders that contain dashboards or other folders"
  type        = bool
  default     = true
}
