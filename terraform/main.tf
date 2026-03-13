data "azurerm_client_config" "current" {}

resource "random_string" "storage_suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  normalized_prefix = substr(join("", regexall("[a-z0-9]", lower(var.storage_account_name_prefix))), 0, 18)
  storage_name      = substr("${local.normalized_prefix}${random_string.storage_suffix.result}", 0, 24)

  default_federated_subjects = [
    "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
    "repo:${var.github_org}/${var.github_repo}:environment:appliance-build"
  ]

  effective_federated_subjects = length(var.federated_subjects) > 0 ? var.federated_subjects : local.default_federated_subjects
}

resource "azurerm_resource_group" "artifacts" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "artifacts" {
  name                          = local.storage_name
  resource_group_name           = azurerm_resource_group.artifacts.name
  location                      = azurerm_resource_group.artifacts.location
  account_tier                  = "Standard"
  account_replication_type      = "LRS"
  min_tls_version               = "TLS1_2"
  public_network_access_enabled = true
  allow_nested_items_to_be_public = true
  tags                          = var.tags
}

resource "azurerm_storage_container" "appliances" {
  name                  = var.storage_container_name
  storage_account_name  = azurerm_storage_account.artifacts.name
  container_access_type = "blob"
}

resource "azurerm_storage_container" "files" {
  name                  = "files"
  storage_account_name  = azurerm_storage_account.artifacts.name
  container_access_type = "blob"
}

resource "azuread_application" "github_actions" {
  display_name = "gh-${var.github_org}-${var.github_repo}-appliance-upload"
}

resource "azuread_service_principal" "github_actions" {
  client_id = azuread_application.github_actions.client_id
}

resource "azuread_application_federated_identity_credential" "github_actions" {
  for_each = toset(local.effective_federated_subjects)

  application_object_id = azuread_application.github_actions.object_id
  display_name          = "gh-${replace(replace(each.value, ":", "-"), "/", "-")}"
  description           = "GitHub Actions OIDC subject ${each.value}"
  audiences             = ["api://AzureADTokenExchange"]
  issuer                = "https://token.actions.githubusercontent.com"
  subject               = each.value
}

resource "azurerm_role_assignment" "blob_data_contributor" {
  scope                             = azurerm_storage_account.artifacts.id
  role_definition_name              = "Storage Blob Data Contributor"
  principal_id                      = azuread_service_principal.github_actions.object_id
  skip_service_principal_aad_check  = true
}
