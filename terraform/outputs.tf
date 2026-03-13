output "azure_tenant_id" {
  description = "Set this as GitHub secret AZURE_TENANT_ID."
  value       = data.azurerm_client_config.current.tenant_id
}

output "azure_subscription_id" {
  description = "Set this as GitHub secret AZURE_SUBSCRIPTION_ID."
  value       = data.azurerm_client_config.current.subscription_id
}

output "azure_client_id" {
  description = "Set this as GitHub secret AZURE_CLIENT_ID."
  value       = azuread_application.github_actions.client_id
}

output "azure_storage_account" {
  description = "Set this as repo variable AZURE_STORAGE_ACCOUNT."
  value       = azurerm_storage_account.artifacts.name
}

output "azure_storage_container" {
  description = "Set this as repo variable AZURE_STORAGE_CONTAINER."
  value       = azurerm_storage_container.appliances.name
}

output "azure_storage_files_container" {
  description = "Files container for dashboards and supporting build artifacts."
  value       = azurerm_storage_container.files.name
}

output "federated_subjects" {
  description = "GitHub OIDC subjects currently allowed in the Entra app."
  value       = local.effective_federated_subjects
}
