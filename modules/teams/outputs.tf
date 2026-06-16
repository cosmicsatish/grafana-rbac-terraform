output "team_uids" {
  description = "Map of team names to UIDs"
  value       = { for name, team in grafana_team.all : name => team.team_uid }
}

output "team_ids" {
  description = "Map of team names to numeric IDs (as strings)"
  value       = { for name, team in grafana_team.all : name => tostring(team.id) }
}
