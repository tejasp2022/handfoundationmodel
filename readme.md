Requirements
- An Azure account with an active subscription  
- Homebrew 
-  GPU quota in Azure
---
Steps

1. Create a .env file in the repo root with the following content:
    ```bash
    AZURE_SUBSCRIPTION_ID=<ID>
    AZURE_REGION=westus
    AZURE_VM_SIZE=Standard_NC4as_T4_v3
    ```
2. Run `./provision_infra.sh`
3. Run
    ```bash
    cd terraform
    terraform init
    terraform plan -out=tfplan
    terraform apply tfplan
    ```
