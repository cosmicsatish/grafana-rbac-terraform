variable "roles" {
  description = "Roles configuration"
  type = map(object({
    description = string
    permissions = map(string)
  }))
  default = {}
}
