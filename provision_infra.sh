#!/bin/bash
set -e

echo "Initializing HaMeR provisioning (idempotent)..."

# --- Load environment variables ---
if [ -f .env ]; then
  echo "Loading environment variables from .env..."
  export $(grep -v '^#' .env | xargs)
else
  echo "Missing .env file. Please create one with:"
  echo "   AZURE_SUBSCRIPTION_ID=<your-subscription-id>"
  echo "   AZURE_REGION=<region>"
  echo "   AZURE_VM_SIZE=<vm-size>"
  exit 1
fi

# --- Validate required files ---
REQUIRED_FILES=(
  "_DATA/data/mano/MANO_LEFT.pkl"
  "_DATA/data/mano/MANO_RIGHT.pkl"
  "video_to_mesh.py"
)

for f in "${REQUIRED_FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "Required file missing: $f"
    echo "Please ensure this file exists before running the script."
    exit 1
  fi
done
echo "All required files found."

# --- SSH key setup ---
SSH_KEY_DIR="$HOME/.ssh"
SSH_KEY_NAME="hand_model_vm_ssh_key"
SSH_KEY_PATH="$SSH_KEY_DIR/$SSH_KEY_NAME"

mkdir -p "$SSH_KEY_DIR"

if [ ! -f "$SSH_KEY_PATH" ]; then
  echo "Creating new SSH key: $SSH_KEY_NAME..."
  ssh-keygen -t rsa -b 4096 -C "hamer-deploy@$(hostname)" -f "$SSH_KEY_PATH" -N "" >/dev/null
  chmod 600 "$SSH_KEY_PATH"
  chmod 644 "$SSH_KEY_PATH.pub"
else
  echo "SSH key already exists at $SSH_KEY_PATH"
fi

# --- Homebrew + Terraform setup ---
if ! command -v brew >/dev/null 2>&1; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
  echo "Homebrew already installed."
fi

if ! command -v terraform >/dev/null 2>&1; then
  echo "Installing Terraform (latest, via HashiCorp tap)..."
  brew tap hashicorp/tap
  brew install hashicorp/tap/terraform
else
  echo "Terraform already installed. Upgrading via HashiCorp tap..."
  brew tap hashicorp/tap
  brew upgrade hashicorp/tap/terraform || true
fi

# --- Directory structure ---
mkdir -p terraform
echo "Ensured directory structure exists."

# --- Terraform configuration ---
cd terraform

cat <<'EOF' > main.tf
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.110"
    }
  }
  required_version = ">= 1.5.0"
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "region" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "vm_size" {
  description = "VM size"
  type        = string
  default     = "Standard_NC4as_T4_v3"
}

resource "azurerm_resource_group" "hamer_rg" {
  name     = "hamer-rg"
  location = var.region
}

resource "azurerm_virtual_network" "hamer_vnet" {
  name                = "hamer-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = var.region
  resource_group_name = azurerm_resource_group.hamer_rg.name
}

resource "azurerm_subnet" "hamer_subnet" {
  name                 = "hamer-subnet"
  resource_group_name  = azurerm_resource_group.hamer_rg.name
  virtual_network_name = azurerm_virtual_network.hamer_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "hamer_ip" {
  name                = "hamer-public-ip"
  location            = var.region
  resource_group_name = azurerm_resource_group.hamer_rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_security_group" "hamer_nsg" {
  name                = "hamer-nsg"
  location            = var.region
  resource_group_name = azurerm_resource_group.hamer_rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "hamer_nic" {
  name                = "hamer-nic"
  location            = var.region
  resource_group_name = azurerm_resource_group.hamer_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.hamer_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.hamer_ip.id
  }
}

resource "azurerm_network_interface_security_group_association" "nsg_assoc" {
  network_interface_id      = azurerm_network_interface.hamer_nic.id
  network_security_group_id = azurerm_network_security_group.hamer_nsg.id
}

resource "azurerm_linux_virtual_machine" "hamer_vm" {
  name                = "hamer-vm"
  location            = var.region
  resource_group_name = azurerm_resource_group.hamer_rg.name
  size                = var.vm_size
  admin_username      = "azureuser"
  network_interface_ids = [azurerm_network_interface.hamer_nic.id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/hand_model_vm_ssh_key.pub")
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  os_disk {
    name                = "hamer-osdisk"
    caching             = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init.sh", {}))

  tags = {
    project = "hamer"
  }
}

output "ssh_command" {
  value = "ssh azureuser@${azurerm_public_ip.hamer_ip.ip_address}"
}
EOF

# --- Cloud-init script for VM ---
cat <<'EOF' > cloud-init.sh
#!/bin/bash
set -e

apt-get update -y
apt-get install -y docker.io docker-compose git

systemctl enable docker
systemctl start docker

cd /home/azureuser
git clone https://github.com/geopavlakos/hamer.git
cd hamer/docker
docker compose up -d
EOF

# --- Terraform variable file ---
cat <<EOF > terraform.tfvars
subscription_id = "${AZURE_SUBSCRIPTION_ID}"
region          = "${AZURE_REGION}"
vm_size         = "${AZURE_VM_SIZE}"
EOF

echo "✅ Terraform configuration prepared."

echo
echo "Next steps:"
echo "  1. az login"
echo "  2. cd terraform"
echo "  3. terraform init"
echo "  4. terraform plan -out=tfplan"
echo "  5. terraform apply tfplan"
echo
echo "SSH key path: $SSH_KEY_PATH"
