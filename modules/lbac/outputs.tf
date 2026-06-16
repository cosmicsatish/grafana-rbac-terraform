output "datasources_with_lbac" {
  description = "Names of datasources that have LBAC rules applied"
  value       = keys(grafana_data_source_config_lbac_rules.lbac)
}
