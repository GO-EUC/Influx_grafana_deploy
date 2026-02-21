# Azure Bootstrap Terraform

Creates the Azure prerequisites for GitHub Actions appliance publishing:

- Resource group
- Storage account
- Blob container
- Entra app registration + service principal
- GitHub OIDC federated credentials
- `Storage Blob Data Contributor` role assignment

## Usage

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init
terraform plan
terraform apply
bash export_outputs.sh
```

This writes Terraform outputs to:

- `outputs.json` (latest)
- `outputs-YYYYMMDD-HHMMSS.json` (history snapshot)

These files are excluded from git via repository `.gitignore`.

After apply, copy output values into GitHub:

- Secrets:
  - `AZURE_CLIENT_ID`
  - `AZURE_TENANT_ID`
  - `AZURE_SUBSCRIPTION_ID`
- Variables:
  - `AZURE_STORAGE_ACCOUNT`
  - `AZURE_STORAGE_CONTAINER`
