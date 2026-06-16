# Folders Module - flat 2-level hierarchy (osttra root + direct children)

resource "grafana_folder" "root" {
  for_each = {
    for name, config in var.folders : name => config
    if try(config.parent_key, null) == null
  }
  title                        = each.key
  prevent_destroy_if_not_empty = var.prevent_destroy_if_not_empty
}

resource "grafana_folder" "child" {
  for_each = {
    for name, config in var.folders : name => config
    if try(config.parent_key, null) != null
  }
  title                        = each.key
  parent_folder_uid            = try(grafana_folder.root[each.value.parent_key].uid, null)
  prevent_destroy_if_not_empty = var.prevent_destroy_if_not_empty
  depends_on                   = [grafana_folder.root]
}

locals {
  all_folders = merge(
    { for name, folder in grafana_folder.root : name => { uid = folder.uid, id = folder.id } },
    { for name, folder in grafana_folder.child : name => { uid = folder.uid, id = folder.id } }
  )
}
