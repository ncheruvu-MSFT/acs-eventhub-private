# ============================================================================
# Input Variables
# ============================================================================

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-acs-eh-nonprod"
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus2"
}

variable "base_name" {
  description = "Base name used to derive resource names"
  type        = string
  default     = "acseh"

  validation {
    condition     = length(var.base_name) >= 3 && length(var.base_name) <= 20
    error_message = "base_name must be between 3 and 20 characters."
  }
}

# VNet + subnets are created in vnet.tf — no manual subnet IDs needed

variable "service_bus_sku" {
  description = "Service Bus SKU (Premium required for Private Endpoints and NSP)"
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Premium"], var.service_bus_sku)
    error_message = "service_bus_sku must be 'Standard' or 'Premium'."
  }
}

variable "queue_name" {
  description = "Service Bus queue name for ACS events"
  type        = string
  default     = "acs-events"
}

variable "acs_data_location" {
  description = "ACS resource data location"
  type        = string
  default     = "United States"

  validation {
    condition     = contains(["United States", "Europe", "Asia Pacific", "Australia"], var.acs_data_location)
    error_message = "acs_data_location must be one of: United States, Europe, Asia Pacific, Australia."
  }
}

variable "container_image" {
  description = "Container image (leave empty for initial deploy; set after ACR build)"
  type        = string
  default     = ""
}

variable "deploy_nsp" {
  description = "Deploy Network Security Perimeter (requires NSP feature on subscription)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default = {
    environment = "nonprod"
    purpose     = "acs-eventhub-private"
  }
}
