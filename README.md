# ACS + Service Bus + Container App — Private Deployment (Terraform)

Deploys **Azure Communication Services (ACS)** with **Service Bus Queue**, **Event Grid**, **Container App**, and **App Gateway (WAF v2)** using **Terraform** — with optional **Network Security Perimeter (NSP)** + **Private Link** (when using Premium SKU).

## Architecture

```
  PUBLIC ZONE — cannot be made private
  ┌─────────────────────────────────────────────────────────────────┐
  │                                                                  │
  │  ┌─────────────┐  voice/call  ┌───────────────────────┐        │
  │  │     ACS      │────────────▶│  App Gateway (WAF v2) │        │
  │  │  Voice+Events│             │  Public entry point    │        │
  │  └──────┬───────┘             └───────────┬───────────┘        │
  │         │ events                          │ routes to app      │
  │         ▼                                 │                     │
  │  ┌──────────────────┐                    │                     │
  │  │ Event Grid Topic  │ managed identity  │                     │
  │  │ (auto-created,    │ crosses zone      │                     │
  │  │  no PE available) │ boundary          │                     │
  │  └────────┬──────────┘                   │                     │
  └───────────┼──────────────────────────────┼─────────────────────┘
              │                              │
  PRIVATE ZONE — Microsoft backbone + Private Link (Premium SKU)
  ┌───────────┼──────────────────────────────┼─────────────────────┐
  │           ▼                              │                     │
  │  ┌──────────────────┐                   │                     │
  │  │ Service Bus Queue │                   │                     │
  │  │ (locked mailbox,  │                   │                     │
  │  │  MS backbone)     │                   │                     │
  │  └────────┬──────────┘                   │                     │
  │           │ PE (Premium only)            │                     │
  │           ▼                              ▼                     │
  │  ┌─────────────────────────────────────────────┐              │
  │  │  Container App (VNet-injected)               │              │
  │  │  Polls queue, hosts voice callback handler   │              │
  │  └─────────────────────────────────────────────┘              │
  └────────────────────────────────────────────────────────────────┘
```

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | >= 2.50 | Authentication & ACR image build |
| [Terraform](https://developer.hashicorp.com/terraform/install) | >= 1.5 | Infrastructure provisioning |
| **Azure subscription** | — | Contributor or Owner role required |

## Quick Start (Terraform)

### 1. Clone the repo

```bash
git clone https://github.com/<your-org>/acs-eventhub-private.git
cd acs-eventhub-private
```

### 2. Authenticate with Azure

```bash
az login
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"
```

### 3. Configure variables

Edit `infra/terraform/terraform.tfvars` with your values:

```hcl
subscription_id     = "<YOUR_SUBSCRIPTION_ID>"
resource_group_name = "rg-acs-eh-nonprod"
location            = "eastus2"
base_name           = "acseh"

# "Standard" (~$0.33/day) or "Premium" (~$22/day, enables PE + NSP)
service_bus_sku   = "Standard"
queue_name        = "acs-events"
acs_data_location = "United States"

# Leave empty for initial deploy; set after ACR build
container_image = ""

# NSP requires subscription-level feature; set true only if available
deploy_nsp = false
```

### 4. Deploy with the helper script (recommended)

The script handles `terraform init`, `apply`, ACR image build, and Container App update in one shot:

```powershell
.\deploy-terraform.ps1 -AutoApprove
# Or with explicit parameters:
.\deploy-terraform.ps1 -SubscriptionId "<SUB_ID>" -Location "eastus2" -ResourceGroupName "rg-acs-eh-nonprod"
```

### 5. Deploy manually (step-by-step)

```bash
cd infra/terraform

terraform init -upgrade

terraform plan \
  -var "subscription_id=<SUB_ID>" \
  -var "resource_group_name=rg-acs-eh-nonprod" \
  -var "location=eastus2"

terraform apply \
  -var "subscription_id=<SUB_ID>" \
  -var "resource_group_name=rg-acs-eh-nonprod" \
  -var "location=eastus2"
```

After Terraform completes, build and push the sample app image:

```bash
ACR_NAME=$(terraform output -raw acr_name)
APP_NAME=$(terraform output -raw container_app_name)

az acr build --registry $ACR_NAME --image acs-sample:latest --file ../app/Dockerfile ../app

az containerapp registry set \
  --name $APP_NAME \
  --resource-group rg-acs-eh-nonprod \
  --server $(terraform output -raw acr_login_server) \
  --identity system

az containerapp update \
  --name $APP_NAME \
  --resource-group rg-acs-eh-nonprod \
  --image "$(terraform output -raw acr_login_server)/acs-sample:latest"
```

### 6. Validate the deployment

```powershell
.\test.ps1 -ResourceGroupName "rg-acs-eh-nonprod"
```

### 7. Tear down

```bash
cd infra/terraform
terraform destroy
```

## Terraform File Layout

```
infra/terraform/
├── providers.tf      # azurerm ~> 4.0, azapi ~> 2.0, random ~> 3.0
├── variables.tf      # All input variables with validation
├── terraform.tfvars  # Default values (edit before deploy)
├── main.tf           # RG, Log Analytics, ACR, Service Bus, ACS, Event Grid
├── vnet.tf           # VNet, 3 subnets (PE, ACA, App GW), NSGs
├── network.tf        # Private DNS, Private Endpoint, NSP (Premium only)
├── container.tf      # Container App Environment + Container App + RBAC
├── appgw.tf          # Application Gateway WAF v2
└── outputs.tf        # Resource names, IDs, FQDNs, public IP
```

## What Gets Deployed

| Resource | Zone | Purpose |
|---|---|---|
| Azure Communication Services | Public (global) | Voice, SMS, chat, email |
| Event Grid System Topic | Public (global) | Routes ACS events to Service Bus |
| App Gateway WAF v2 | Public | Entry point for ACS voice callbacks |
| Service Bus Namespace + Queue | Private (with Premium: PE + NSP) | Durable event mailbox |
| Private Endpoint (Premium only) | Private | Defense-in-depth for SB data plane |
| Private DNS Zone (Premium only) | Private | Resolves SB to private IP |
| NSP (Premium + `deploy_nsp`) | Private | Enforced perimeter around Service Bus |
| Container App Environment | Private | VNet-injected |
| Container App | Private | Polls queue, processes events, voice callback handler |
| Azure Container Registry | Shared | Hosts the sample app image |
| Log Analytics | Shared | Diagnostics for all resources |
| RBAC Assignments | N/A | Event Grid → SB Sender, App → SB Receiver, App → AcrPull |

### Service Bus SKU Options

| SKU | Cost | Private Endpoints | NSP | Best For |
|---|---|---|---|---|
| **Standard** | ~$0.33/day | No | No | Non-prod, cost-sensitive workloads |
| **Premium** | ~$22/day | Yes | Yes | Production with full network isolation |

### Key Terraform Variables

| Variable | Default | Description |
|---|---|---|
| `subscription_id` | — | Azure subscription ID (required) |
| `resource_group_name` | `rg-acs-eh-nonprod` | Target resource group |
| `location` | `eastus2` | Azure region |
| `base_name` | `acseh` | Prefix for all resource names |
| `service_bus_sku` | `Standard` | `Standard` or `Premium` |
| `deploy_nsp` | `false` | Enable Network Security Perimeter |
| `container_image` | `""` | Custom image (empty = MCR quickstart) |

## Network Traffic Flow

| Traffic Type | Path | Public Endpoint? |
|---|---|---|
| Event notifications (SMS, chat, etc.) | ACS → Event Grid → **Service Bus Queue** → Container App polls | **No** |
| Voice call-control callbacks | ACS → **App Gateway WAF v2** → Container App `/api/callback` | **Yes** |
| Outbound REST API calls | Container App → NAT Gateway → ACS public APIs | N/A (outbound) |

> **No voice?** If you only use SMS/chat/email, the Event Grid → Service Bus → queue polling path is fully private and no App Gateway is needed.

## Sample App Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Health check for App Gateway and ACA probes |
| POST | `/api/callback` | ACS voice callback (IncomingCall webhook) |
| GET | `/api/events` | View recent events from Service Bus queue |
| POST | `/api/test/voice` | Simulate ACS voice IncomingCall event |
| POST | `/api/test/chat` | Simulate ACS chat message event |
| POST | `/api/test/sms` | Simulate ACS SMS received event |
| GET | `/api/test/queue` | Send a test message to Service Bus queue |
| GET | `/api/test/validate` | Run full end-to-end validation |

## Remote State (Optional)

Uncomment the backend block in `infra/terraform/providers.tf` and configure:

```hcl
backend "azurerm" {
  resource_group_name  = "rg-terraform-state"
  storage_account_name = "tfstateacseh"
  container_name       = "tfstate"
  key                  = "acs-eventhub-private.tfstate"
}
```

## Remaining Work

1. **WAF policy** — WAF v2 SKU is deployed but no `firewallPolicy` resource is attached (OWASP 3.2 rules inactive).
2. **Callback authentication** — `/api/callback` does not validate request authenticity; add HMAC/signature verification.
3. **ACA internal mode** — `internal_load_balancer_enabled` is `false`; set to `true` and route App Gateway to the private IP for a fully private setup.

## License

This project is licensed under the [MIT License](LICENSE).
| 6 | DNS resolution | CNAME → privatelink (Premium, best-effort from non-VNet) |
| 7 | App Gateway | Operational state, backend health probe |
| 8 | Container App | Running state, image, environment config |
| 9 | ACS connectivity | Key/connection string retrieval |

## Security Summary

- **Service Bus:** `minimumTlsVersion: 1.2`, Private Endpoint + NSP when Premium SKU
- **Container App:** VNet-injected, NAT Gateway for outbound
- **App Gateway:** WAF v2 SKU (WAF policy attachment is a remaining work item)
- **Event Grid → Service Bus:** Managed identity + RBAC (Azure Service Bus Data Sender)
- **Container App → Service Bus:** Managed identity + RBAC (Azure Service Bus Data Receiver)
- **Container App → ACR:** System-assigned managed identity + RBAC (AcrPull)
- **All diagnostics** → Log Analytics workspace

## Cleanup

```powershell
az group delete --name "rg-acs-eh-nonprod" --yes --no-wait
```
