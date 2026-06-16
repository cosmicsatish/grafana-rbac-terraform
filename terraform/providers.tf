terraform {
  required_version = "1.15.4" # Pinned to CI version; update CI workflows when bumping

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "4.23.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.5.0"
    }
  }
}

provider "grafana" {
  url  = var.grafana_url
  auth = var.grafana_token
}