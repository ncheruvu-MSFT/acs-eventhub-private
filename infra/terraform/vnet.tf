# ============================================================================
# VNet + Subnets + NSGs
# ============================================================================

locals {
  vnet_name       = "vnet-${var.base_name}-${var.resource_group_name}"
  vnet_cidr       = "10.1.0.0/16"
  pe_subnet_cidr  = "10.1.0.0/24"
  agw_subnet_cidr = "10.1.1.0/24"
  aca_subnet_cidr = "10.1.2.0/23"
}

# ═══════════════════════════════════════════════════════════════════════════
# Virtual Network
# ═══════════════════════════════════════════════════════════════════════════
resource "azurerm_virtual_network" "main" {
  name                = local.vnet_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [local.vnet_cidr]
  tags                = var.tags
}

# ═══════════════════════════════════════════════════════════════════════════
# PE Subnet (Private Endpoints)
# ═══════════════════════════════════════════════════════════════════════════
resource "azurerm_subnet" "pe" {
  name                              = "snet-pe"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [local.pe_subnet_cidr]
  private_endpoint_network_policies = "Enabled"
}

# ═══════════════════════════════════════════════════════════════════════════
# App Gateway Subnet + NSG
# ═══════════════════════════════════════════════════════════════════════════
resource "azurerm_network_security_group" "agw" {
  name                = "${local.vnet_name}-snet-agw-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  security_rule {
    name                       = "AllowGatewayManagerInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHTTPInbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet" "agw" {
  name                 = "snet-agw"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.agw_subnet_cidr]
}

resource "azurerm_subnet_network_security_group_association" "agw" {
  subnet_id                 = azurerm_subnet.agw.id
  network_security_group_id = azurerm_network_security_group.agw.id
}

# ═══════════════════════════════════════════════════════════════════════════
# ACA Subnet (delegated to Microsoft.App/environments, /23 minimum)
# ═══════════════════════════════════════════════════════════════════════════
resource "azurerm_subnet" "aca" {
  name                 = "snet-aca"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.aca_subnet_cidr]

  delegation {
    name = "aca-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}
