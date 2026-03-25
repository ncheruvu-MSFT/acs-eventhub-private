# ============================================================================
# Private DNS Zones, Private Endpoint, Network Security Perimeter (NSP)
# ============================================================================

# ═══════════════════════════════════════════════════════════════════════════
# Service Bus Private DNS Zone + Private Endpoint (Premium SKU only)
# ═══════════════════════════════════════════════════════════════════════════

resource "azurerm_private_dns_zone" "sb" {
  count               = local.is_premium ? 1 : 0
  name                = "privatelink.servicebus.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "sb" {
  count                 = local.is_premium ? 1 : 0
  name                  = "${azurerm_virtual_network.main.name}-sb-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.sb[0].name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "sb" {
  count               = local.is_premium ? 1 : 0
  name                = "${local.sb_namespace_name}-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "${local.sb_namespace_name}-plsc"
    private_connection_resource_id = azurerm_servicebus_namespace.main.id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.sb[0].id]
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# Network Security Perimeter (NSP) – Preview API via azapi
# Wraps Service Bus in a security perimeter. Resources inside the
# perimeter can communicate freely; everything else is blocked.
# ═══════════════════════════════════════════════════════════════════════════

# 1. The perimeter itself
resource "azapi_resource" "nsp" {
  count     = local.deploy_nsp_resources ? 1 : 0
  type      = "Microsoft.Network/networkSecurityPerimeters@2023-08-01-preview"
  name      = local.nsp_name
  location  = azurerm_resource_group.main.location
  parent_id = azurerm_resource_group.main.id
  tags      = var.tags
  body      = {}
}

# 2. NSP Profile – defines access rules for this perimeter
resource "azapi_resource" "nsp_profile" {
  count     = local.deploy_nsp_resources ? 1 : 0
  type      = "Microsoft.Network/networkSecurityPerimeters/profiles@2023-08-01-preview"
  name      = "default-profile"
  location  = azurerm_resource_group.main.location
  parent_id = azapi_resource.nsp[0].id
  tags      = var.tags
  body      = {}
}

# 3. Inbound access rule: Allow Event Grid (same subscription PaaS services)
resource "azapi_resource" "nsp_rule_eventgrid" {
  count     = local.deploy_nsp_resources ? 1 : 0
  type      = "Microsoft.Network/networkSecurityPerimeters/profiles/accessRules@2023-08-01-preview"
  name      = "allow-eventgrid-inbound"
  location  = azurerm_resource_group.main.location
  parent_id = azapi_resource.nsp_profile[0].id
  tags      = var.tags

  body = {
    properties = {
      direction = "Inbound"
      subscriptions = [
        { id = "/subscriptions/${var.subscription_id}" }
      ]
    }
  }
}

# 4. Inbound access rule: Allow the ACA subnet (VNet-based inbound)
resource "azapi_resource" "nsp_rule_aca" {
  count     = local.deploy_nsp_resources ? 1 : 0
  type      = "Microsoft.Network/networkSecurityPerimeters/profiles/accessRules@2023-08-01-preview"
  name      = "allow-aca-subnet-inbound"
  location  = azurerm_resource_group.main.location
  parent_id = azapi_resource.nsp_profile[0].id
  tags      = var.tags

  body = {
    properties = {
      direction = "Inbound"
      subscriptions = [
        { id = "/subscriptions/${var.subscription_id}" }
      ]
    }
  }
}

# 5. Associate Service Bus Namespace with the NSP (Enforced mode)
resource "azapi_resource" "nsp_association_sb" {
  count     = local.deploy_nsp_resources ? 1 : 0
  type      = "Microsoft.Network/networkSecurityPerimeters/resourceAssociations@2023-08-01-preview"
  name      = "sb-namespace-association"
  location  = azurerm_resource_group.main.location
  parent_id = azapi_resource.nsp[0].id
  tags      = var.tags

  body = {
    properties = {
      privateLinkResource = {
        id = azurerm_servicebus_namespace.main.id
      }
      profile = {
        id = azapi_resource.nsp_profile[0].id
      }
      accessMode = "Enforced"
    }
  }
}
