# ---------------------------------------------------------------------------
# App Service Plan - hosts both Function Apps
# ---------------------------------------------------------------------------
resource "azurerm_service_plan" "main" {
  name                = "${var.name_prefix}-plan"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = var.service_plan_sku
}

# ---------------------------------------------------------------------------
# Function App packages - one per app, each zipped from inside its directory
# so host.json lands at the root of the archive. Run `npm install` in each
# app's directory first so its node_modules are included.
#
# The archive's name carries a hash of the app's directory (see locals.tf).
# The provider only redeploys when zip_deploy_file changes, so a fixed name
# would leave code changes undeployed.
# ---------------------------------------------------------------------------
data "archive_file" "function" {
  for_each = local.function_apps

  type        = "zip"
  source_dir  = "${local.functions_dir}/${each.key}"
  output_path = "${path.module}/../../.build/${each.key}-${local.function_hashes[each.key]}.zip"
}

# ---------------------------------------------------------------------------
# The two Function Apps, with their code.
#
# zip_deploy_file pushes each package over the site's SCM plane during apply,
# so a single `terraform apply` leaves running apps rather than empty ones.
# WEBSITE_RUN_FROM_PACKAGE = "1" is what the provider requires alongside it.
#
# Every function uses authLevel "function", so a request without a function
# key gets a 401. API Management holds each app's default host key (see
# 5-api-management.tf) and adds it to the requests it forwards, which makes
# the gateway the way in.
# ---------------------------------------------------------------------------
resource "azurerm_linux_function_app" "main" {
  for_each = local.function_apps

  name                = "${var.name_prefix}-${each.key}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.main.id
  https_only          = true
  tags                = var.tags

  storage_account_name          = azurerm_storage_account.main.name
  storage_uses_managed_identity = true

  zip_deploy_file = data.archive_file.function[each.key].output_path

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.functions.id]
  }

  site_config {
    application_stack {
      node_version = "22"
    }
  }

  app_settings = {
    FUNCTIONS_WORKER_RUNTIME = "node"

    # Required by the provider whenever zip_deploy_file is set.
    WEBSITE_RUN_FROM_PACKAGE = "1"

    # The host's own storage, over the managed identity.
    AzureWebJobsStorage__credential = "managedidentity"
    AzureWebJobsStorage__clientId   = azurerm_user_assigned_identity.functions.client_id
  }

  # The identity must hold its roles before the host starts and opens its
  # storage.
  depends_on = [azurerm_role_assignment.storage]
}

# ---------------------------------------------------------------------------
# Each app's host keys. API Management stores the default function key as a
# secret named value, so it never appears in a policy or an app setting.
# ---------------------------------------------------------------------------
data "azurerm_function_app_host_keys" "main" {
  for_each = local.function_apps

  name                = azurerm_linux_function_app.main[each.key].name
  resource_group_name = azurerm_resource_group.main.name
}
