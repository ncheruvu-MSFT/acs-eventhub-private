# ============================================================================
# Core Resources: RG, Log Analytics, ACR, Service Bus, ACS, Event Grid
# ============================================================================

# ---------------------------------------------------------------------------
# Random suffix (replaces Bicep uniqueString)
# ---------------------------------------------------------------------------
resource "random_string" "suffix" {
  length  = 13
  special = false
  upper   = false

  keepers = {
    resource_group_name = var.resource_group_name
    base_name           = var.base_name
  }
}

locals {
  unique_suffix         = random_string.suffix.result
  log_analytics_name    = "${var.base_name}-la-${local.unique_suffix}"
  sb_namespace_name     = "${var.base_name}-sb-${local.unique_suffix}"
  acs_name              = "${var.base_name}-acs-${local.unique_suffix}"
  event_grid_topic_name = "${var.base_name}-egt-${local.unique_suffix}"
  aca_env_name          = "${var.base_name}-env-${local.unique_suffix}"
  container_app_name    = "${var.base_name}-app-${local.unique_suffix}"
  acr_name              = replace("${var.base_name}acr${local.unique_suffix}", "-", "")
  nsp_name              = "${var.base_name}-nsp-${local.unique_suffix}"
  appgw_name            = "${var.base_name}-agw-${local.unique_suffix}"
  appgw_pip_name        = "${var.base_name}-agw-pip-${local.unique_suffix}"

  is_premium           = var.service_bus_sku == "Premium"
  deploy_nsp_resources = var.deploy_nsp && local.is_premium
  effective_image      = var.container_image != "" ? var.container_image : "mcr.microsoft.com/k8se/quickstart:latest"
}

# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ═══════════════════════════════════════════════════════════════════════════
# SHARED: Log Analytics
# ═══════════════════════════════════════════════════════════════════════════
resource "azurerm_log_analytics_workspace" "main" {
  name                = local.log_analytics_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# ═══════════════════════════════════════════════════════════════════════════
# SHARED: Azure Container Registry (ACR) – for sample app image
# ═══════════════════════════════════════════════════════════════════════════
resource "azurerm_container_registry" "main" {
  name                = local.acr_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Basic"
  admin_enabled       = false
  tags                = var.tags
}

# ═══════════════════════════════════════════════════════════════════════════
# Service Bus Namespace + Queue
# ═══════════════════════════════════════════════════════════════════════════
resource "azurerm_servicebus_namespace" "main" {
  name                          = local.sb_namespace_name
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  sku                           = var.service_bus_sku
  capacity                      = local.is_premium ? 1 : 0
  premium_messaging_partitions  = local.is_premium ? 1 : 0
  public_network_access_enabled = local.deploy_nsp_resources ? false : true
  minimum_tls_version           = "1.2"
  local_auth_enabled            = true # SAS for test; set false + RBAC in prod
  tags                          = var.tags
}

resource "azurerm_servicebus_queue" "main" {
  name                                 = var.queue_name
  namespace_id                         = azurerm_servicebus_namespace.main.id
  lock_duration                        = "PT1M"
  max_size_in_megabytes                = 1024
  requires_duplicate_detection         = false
  requires_session                     = false
  dead_lettering_on_message_expiration = true
  max_delivery_count                   = 10
}

# Reference built-in auth rule for connection string retrieval
data "azurerm_servicebus_namespace_authorization_rule" "root" {
  name         = "RootManageSharedAccessKey"
  namespace_id = azurerm_servicebus_namespace.main.id
}

# Service Bus diagnostics → Log Analytics
resource "azurerm_monitor_diagnostic_setting" "sb" {
  name                       = "sb-diagnostics"
  target_resource_id         = azurerm_servicebus_namespace.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# Azure Communication Services (global – cannot be made private)
# ═══════════════════════════════════════════════════════════════════════════
resource "azurerm_communication_service" "main" {
  name                = local.acs_name
  resource_group_name = azurerm_resource_group.main.name
  data_location       = var.acs_data_location
  tags                = var.tags
}

# ACS diagnostics → Log Analytics
resource "azurerm_monitor_diagnostic_setting" "acs" {
  name                       = "acs-diagnostics"
  target_resource_id         = azurerm_communication_service.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category_group = "allLogs"
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# Event Grid System Topic (ACS source) – no PE available
# Event Grid delivers to Service Bus Queue over Microsoft backbone
# ═══════════════════════════════════════════════════════════════════════════
resource "azurerm_eventgrid_system_topic" "main" {
  name                = local.event_grid_topic_name
  location            = "global"
  resource_group_name = azurerm_resource_group.main.name
  source_resource_id  = azurerm_communication_service.main.id
  topic_type          = "Microsoft.Communication.CommunicationServices"
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# Event Grid subscription → route ACS events to Service Bus Queue
resource "azurerm_eventgrid_system_topic_event_subscription" "main" {
  name                = "acs-to-servicebus"
  system_topic        = azurerm_eventgrid_system_topic.main.name
  resource_group_name = azurerm_resource_group.main.name

  service_bus_queue_endpoint_id = azurerm_servicebus_queue.main.id

  included_event_types = [
    "Microsoft.Communication.SMSReceived",
    "Microsoft.Communication.SMSDeliveryReportReceived",
    "Microsoft.Communication.ChatMessageReceived",
    "Microsoft.Communication.ChatMessageEdited",
    "Microsoft.Communication.ChatMessageDeleted",
    "Microsoft.Communication.ChatThreadCreated",
    "Microsoft.Communication.ChatThreadDeleted",
    "Microsoft.Communication.ChatThreadPropertiesUpdated",
    "Microsoft.Communication.ChatParticipantAdded",
    "Microsoft.Communication.ChatParticipantRemoved",
    "Microsoft.Communication.RecordingFileStatusUpdated",
    "Microsoft.Communication.IncomingCall",
    "Microsoft.Communication.EmailDeliveryReportReceived",
    "Microsoft.Communication.RouterJobReceived",
  ]

  event_delivery_schema = "EventGridSchema"

  retry_policy {
    max_delivery_attempts = 30
    event_time_to_live    = 1440
  }
}

# RBAC: Event Grid managed identity → Azure Service Bus Data Sender
resource "azurerm_role_assignment" "eventgrid_sb_sender" {
  scope                = azurerm_servicebus_namespace.main.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_eventgrid_system_topic.main.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
