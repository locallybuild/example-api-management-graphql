# ---------------------------------------------------------------------------
# The storefront Web App - a dependency-free Node app, zipped from
# app/storefront, that serves the shop's HTML pages.
#
# It refuses any request without the x-api-key that API Management adds, so
# the gateway is the only way in. The key is generated here and given to both
# the app (as the API_KEY app setting) and API Management (as a secret named
# value its backend refers to, see 5-api-management.tf).
#
# The pages get their products and orders from the two GraphQL APIs, which
# the app calls through the gateway like any other caller: with the gateway's
# URL and a subscription key of its own.
#
# It runs on the same App Service plan as the two Function Apps.
# ---------------------------------------------------------------------------
resource "random_password" "storefront_api_key" {
  length  = 32
  special = false
}

# The archive's name carries a hash of the app's directory (see locals.tf), so
# a code change produces a new zip_deploy_file and a redeploy.
data "archive_file" "storefront" {
  type        = "zip"
  source_dir  = local.storefront_dir
  output_path = "${path.module}/../../.build/storefront-${local.storefront_hash}.zip"
}

resource "azurerm_linux_web_app" "storefront" {
  name                = "${var.name_prefix}-storefront"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.main.id
  https_only          = true
  tags                = var.tags

  zip_deploy_file = data.archive_file.storefront.output_path

  site_config {
    application_stack {
      node_version = "24-lts"
    }
  }

  app_settings = {
    # The zip is the app as it runs; there's nothing to build.
    SCM_DO_BUILD_DURING_DEPLOYMENT = "false"

    API_KEY = random_password.storefront_api_key.result

    # Where the GraphQL APIs are, and the key the app calls them with.
    GATEWAY_URL      = azurerm_api_management.main.gateway_url
    SUBSCRIPTION_KEY = azurerm_api_management_subscription.storefront.primary_key
  }
}
