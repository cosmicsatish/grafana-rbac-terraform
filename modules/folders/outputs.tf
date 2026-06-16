output "folder_uids" {
  description = "Map of folder names to UIDs"
  value       = { for name, folder in local.all_folders : name => folder.uid }
}
