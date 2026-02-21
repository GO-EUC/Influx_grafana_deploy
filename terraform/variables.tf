variable "resource_group_name" {
  description = "Resource group for appliance artifacts."
  type        = string
  default     = "rg-goeuc-artifacts"
}

variable "location" {
  description = "Azure region for the storage account."
  type        = string
  default     = "uksouth"
}

variable "storage_account_name_prefix" {
  description = "Prefix used to create a globally unique storage account name."
  type        = string
  default     = "goeucartifacts"
}

variable "storage_container_name" {
  description = "Blob container name used to store appliance artifacts."
  type        = string
  default     = "appliances"
}

variable "github_org" {
  description = "GitHub organization or user that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name."
  type        = string
}

variable "federated_subjects" {
  description = "GitHub OIDC subjects allowed to request Azure tokens."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Optional tags applied to Azure resources."
  type        = map(string)
  default = {
    project = "go-euc"
  }
}
