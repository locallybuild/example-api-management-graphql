# ---------------------------------------------------------------------------
# User-Assigned Managed Identity - both Function Apps run as this identity.
#
# The only thing either app connects to is its host storage, so the identity
# holds just the roles the Functions host needs for that. A user-assigned
# identity exists before the apps do, so the roles are granted before either
# host starts.
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "functions" {
  name                = "${var.name_prefix}-id"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Storage Account - the Functions hosts' own storage (AzureWebJobsStorage),
# where they keep their keys, locks and bookkeeping. The two apps share it:
# each host keeps its state under its own host ID, which comes from the app's
# name.
#
# Shared key access is disabled, so the hosts authenticate with an Entra
# access token for the managed identity rather than an account key.
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "main" {
  name                            = substr(replace(var.name_prefix, "-", ""), 0, 24)
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

# Host keys and leases live in blobs, and the host uses queues internally.
resource "azurerm_role_assignment" "storage" {
  for_each = toset([
    "Storage Blob Data Owner",
    "Storage Queue Data Contributor",
  ])

  scope                = azurerm_storage_account.main.id
  role_definition_name = each.value
  principal_id         = azurerm_user_assigned_identity.functions.principal_id
  principal_type       = "ServicePrincipal"
}
