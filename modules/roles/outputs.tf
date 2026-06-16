output "role_uids" {
  description = "Map of role names to UIDs"
  value       = { for name, role in grafana_role.custom : name => role.uid }
}
