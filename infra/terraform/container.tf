# ============================================================================
# Container App Environment + Container App + RBAC
# ============================================================================

# ═══════════════════════════════════════════════════════════════════════════
# Container App Environment (VNet-injected, consumption workload profile)
# ═══════════════════════════════════════════════════════════════════════════
resource "azurerm_container_app_environment" "main" {
  name                           = local.aca_env_name
  location                       = azurerm_resource_group.main.location
  resource_group_name            = azurerm_resource_group.main.name
  infrastructure_subnet_id       = azurerm_subnet.aca.id
  internal_load_balancer_enabled = false
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.main.id
  tags                           = var.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# Container App – polls Service Bus Queue via PE
# Hosts voice callback handler + queue consumer
# ═══════════════════════════════════════════════════════════════════════════
# Initial deploy uses MCR quickstart image; deploy-terraform.ps1 builds the
# real image in ACR, registers the ACR with system identity, and updates
# the container app image (matching the Bicep deploy.ps1 workflow).
resource "azurerm_container_app" "main" {
  name                         = local.container_app_name
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type = "SystemAssigned"
  }

  ingress {
    external_enabled           = true
    target_port                = 8080
    transport                  = "auto"
    allow_insecure_connections = false

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  secret {
    name  = "sb-connection-string"
    value = data.azurerm_servicebus_namespace_authorization_rule.root.primary_connection_string
  }

  template {
    min_replicas = 0
    max_replicas = 5

    container {
      name   = "acs-sample"
      image  = local.effective_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name        = "SERVICEBUS_CONNECTION_STRING"
        secret_name = "sb-connection-string"
      }

      env {
        name  = "SERVICEBUS_QUEUE_NAME"
        value = var.queue_name
      }

      env {
        name  = "PORT"
        value = "8080"
      }

      liveness_probe {
        transport        = "HTTP"
        path             = "/health"
        port             = 8080
        interval_seconds = 30
      }

      readiness_probe {
        transport        = "HTTP"
        path             = "/health"
        port             = 8080
        interval_seconds = 10
      }
    }

    http_scale_rule {
      name                = "http-scale"
      concurrent_requests = "50"
    }
  }

  # Image and registry are managed by deploy-terraform.ps1 after ACR build
  lifecycle {
    ignore_changes = [
      template[0].container[0].image,
      registry,
    ]
  }
}

# RBAC: Container App managed identity → AcrPull on ACR
resource "azurerm_role_assignment" "container_app_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_container_app.main.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# RBAC: Container App managed identity → Azure Service Bus Data Receiver
resource "azurerm_role_assignment" "container_app_sb_receiver" {
  scope                = azurerm_servicebus_namespace.main.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_container_app.main.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
