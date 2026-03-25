# ============================================================================
# Outputs
# ============================================================================

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "log_analytics_id" {
  value = azurerm_log_analytics_workspace.main.id
}

output "sb_namespace_id" {
  value = azurerm_servicebus_namespace.main.id
}

output "sb_namespace_name" {
  value = azurerm_servicebus_namespace.main.name
}

output "sb_queue_name" {
  value = azurerm_servicebus_queue.main.name
}

output "acs_name" {
  value = azurerm_communication_service.main.name
}

output "acs_id" {
  value = azurerm_communication_service.main.id
}

output "acs_host_name" {
  value = "${azurerm_communication_service.main.name}.communication.azure.com"
}

output "system_topic_name" {
  value = azurerm_eventgrid_system_topic.main.name
}

output "system_topic_id" {
  value = azurerm_eventgrid_system_topic.main.id
}

output "sb_private_endpoint_id" {
  value = local.is_premium ? azurerm_private_endpoint.sb[0].id : "not-deployed"
}

output "aca_environment_name" {
  value = azurerm_container_app_environment.main.name
}

output "container_app_name" {
  value = azurerm_container_app.main.name
}

output "container_app_fqdn" {
  value = azurerm_container_app.main.ingress[0].fqdn
}

output "nsp_name" {
  value = local.deploy_nsp_resources ? azapi_resource.nsp[0].name : "not-deployed"
}

output "nsp_id" {
  value = local.deploy_nsp_resources ? azapi_resource.nsp[0].id : "not-deployed"
}

output "acr_name" {
  value = azurerm_container_registry.main.name
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "app_gateway_name" {
  value = azurerm_application_gateway.main.name
}

output "app_gateway_public_ip" {
  value = azurerm_public_ip.appgw.ip_address
}
