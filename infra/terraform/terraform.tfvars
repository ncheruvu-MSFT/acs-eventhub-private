# ============================================================================
# Default variable values
# Update these for your environment before running terraform apply
# ============================================================================

subscription_id     = "<YOUR_SUBSCRIPTION_ID>"
resource_group_name = "rg-acs-eh-nonprod"
location            = "eastus2"
base_name           = "acseh"

# Service Bus: "Standard" (~$0.33/day) or "Premium" (~$22/day, enables PE + NSP)
service_bus_sku = "Premium"
queue_name      = "acs-events"

acs_data_location = "United States"

# Leave empty for initial deploy; set after ACR build
container_image = ""

# NSP requires subscription-level feature; set true only if available
deploy_nsp = false

tags = {
  environment = "nonprod"
  purpose     = "acs-eventhub-private"
}
