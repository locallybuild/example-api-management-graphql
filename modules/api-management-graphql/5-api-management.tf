# ---------------------------------------------------------------------------
# API Management - the one front door for the three apps.
#
# The gateway picks the API by the first path segment (/catalog, /orders or
# /shop). The two GraphQL APIs need a subscription key: the gateway checks
# it and the product's rate limit, checks the operation against the API's
# schema, then hands the request to the API's backend, which adds the app's
# function key and forwards it. The storefront is a website, so it needs no
# key: its backend adds the Web App's credential.
# ---------------------------------------------------------------------------
resource "azurerm_api_management" "main" {
  name                = "${var.name_prefix}-apim"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = "Developer_1"
  tags                = var.tags
}

locals {
  # One backend and named value per app. url is where the backend sends
  # requests, resource_id links the backend to its app (as Azure's "import
  # from Function App / App Service" does), and header is the credential the
  # app checks. The credentials themselves are in secrets below: a sensitive
  # value can't be part of a for_each map.
  backends = {
    catalog = {
      description = "The catalog Function App's GraphQL endpoint."
      url         = "https://${azurerm_linux_function_app.main["catalog"].default_hostname}/api/graphql"
      resource_id = "https://management.azure.com${azurerm_linux_function_app.main["catalog"].id}"
      header      = "x-functions-key"
      named_value = "catalog-function-key"
    }
    orders = {
      description = "The orders Function App's GraphQL endpoint."
      url         = "https://${azurerm_linux_function_app.main["orders"].default_hostname}/api/graphql"
      resource_id = "https://management.azure.com${azurerm_linux_function_app.main["orders"].id}"
      header      = "x-functions-key"
      named_value = "orders-function-key"
    }
    storefront = {
      description = "The storefront Web App."
      url         = "https://${azurerm_linux_web_app.storefront.default_hostname}"
      resource_id = "https://management.azure.com${azurerm_linux_web_app.storefront.id}"
      header      = "x-api-key"
      named_value = "storefront-api-key"
    }
  }

  # The two GraphQL APIs, one per Function App. Each one's schema is the file
  # its function answers queries against.
  graphql_apis = {
    catalog = {
      display_name = "Catalog"
      schema       = "${local.functions_dir}/catalog/schema.graphql"
    }
    orders = {
      display_name = "Orders"
      schema       = "${local.functions_dir}/orders/schema.graphql"
    }
  }
}

locals {
  secrets = {
    catalog    = data.azurerm_function_app_host_keys.main["catalog"].default_function_key
    orders     = data.azurerm_function_app_host_keys.main["orders"].default_function_key
    storefront = random_password.storefront_api_key.result
  }
}

# ---------------------------------------------------------------------------
# Named values - each app's credential, stored as a secret so it isn't shown
# in the portal or returned by a plain GET. The backends refer to them as
# {{<name>}}, and the gateway substitutes the value per request.
# ---------------------------------------------------------------------------
resource "azurerm_api_management_named_value" "main" {
  for_each = local.backends

  name                = each.value.named_value
  display_name        = each.value.named_value
  resource_group_name = azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name
  value               = local.secrets[each.key]
  secret              = true
}

# ---------------------------------------------------------------------------
# Backends - one per app. Each holds the app's URL and the credential header
# the gateway adds to every request it forwards there, so no policy has to
# set it and callers never see it.
# ---------------------------------------------------------------------------
resource "azurerm_api_management_backend" "main" {
  for_each = local.backends

  name                = each.key
  resource_group_name = azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name
  protocol            = "http"
  url                 = each.value.url
  resource_id         = each.value.resource_id
  description         = each.value.description

  credentials {
    header = {
      (each.value.header) = "{{${azurerm_api_management_named_value.main[each.key].display_name}}}"
    }
  }
}

# ---------------------------------------------------------------------------
# GraphQL APIs - one pass-through API per Function App, at /catalog and
# /orders. A GraphQL API has no operations: its endpoint is the API's URL,
# and the gateway reads the operation from the request, checks it against
# the API's schema, and refuses one that doesn't match without calling the
# app.
#
# service_url is the app's endpoint, which is what makes the API
# pass-through (an API without one is synthetic, answered by resolvers in the
# gateway). The API's policy still sends each request through the backend,
# for its credential.
# ---------------------------------------------------------------------------
resource "azurerm_api_management_api" "graphql" {
  for_each = local.graphql_apis

  name                  = each.key
  display_name          = each.value.display_name
  path                  = each.key
  api_type              = "graphql"
  service_url           = local.backends[each.key].url
  protocols             = ["https"]
  revision              = "1"
  subscription_required = true
  resource_group_name   = azurerm_resource_group.main.name
  api_management_name   = azurerm_api_management.main.name
}

# The schema the gateway checks operations against. It's the same file the
# function serves, so the two can't drift apart.
resource "azurerm_api_management_api_schema" "graphql" {
  for_each = local.graphql_apis

  api_name            = azurerm_api_management_api.graphql[each.key].name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.main.name
  schema_id           = "graphql"
  content_type        = "application/vnd.ms-azure-apim.graphql.schema"
  value               = file(each.value.schema)
}

# ---------------------------------------------------------------------------
# The storefront - an HTTP API at /shop, for the Web App's pages. It needs no
# subscription key, since browsers don't send one, so it isn't part of the
# Shop product.
#
# The gateway strips the API's path and appends the rest of the URL to the
# backend's URL, so
#   GET  <gateway>/shop/products/mug  ->  <storefront app>/products/mug
# ---------------------------------------------------------------------------
resource "azurerm_api_management_api" "storefront" {
  name                  = "storefront"
  display_name          = "Storefront"
  path                  = "shop"
  protocols             = ["https"]
  revision              = "1"
  subscription_required = false
  resource_group_name   = azurerm_resource_group.main.name
  api_management_name   = azurerm_api_management.main.name
}

# The gateway routes only requests that match one of an API's operations, so
# each page and form is declared here. Anything else gets a 404 from the
# gateway without reaching the app.
locals {
  storefront_operations = {
    "list-products" = { method = "GET", url_template = "/", display_name = "Products page" }
    "get-product"   = { method = "GET", url_template = "/products/{id}", display_name = "Product page", params = ["id"] }
    "place-order"   = { method = "POST", url_template = "/products/{id}/orders", display_name = "Place an order", params = ["id"] }
    "add-review"    = { method = "POST", url_template = "/products/{id}/reviews", display_name = "Add a review", params = ["id"] }
    "list-orders"   = { method = "GET", url_template = "/orders", display_name = "Orders page" }
  }
}

resource "azurerm_api_management_api_operation" "storefront" {
  for_each = local.storefront_operations

  operation_id        = each.key
  api_name            = azurerm_api_management_api.storefront.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.main.name
  display_name        = each.value.display_name
  method              = each.value.method
  url_template        = each.value.url_template

  dynamic "template_parameter" {
    for_each = lookup(each.value, "params", [])
    content {
      name     = template_parameter.value
      type     = "string"
      required = true
    }
  }
}

# ---------------------------------------------------------------------------
# API policies - send each request to the API's backend, and mark it as
# having come through the gateway (the apps report this as "via", so you can
# see the path a request took).
# ---------------------------------------------------------------------------
resource "azurerm_api_management_api_policy" "graphql" {
  for_each = local.graphql_apis

  api_name            = azurerm_api_management_api.graphql[each.key].name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.main.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <set-backend-service backend-id="${azurerm_api_management_backend.main[each.key].name}" />
        <set-header name="x-forwarded-by" exists-action="override">
          <value>${azurerm_api_management.main.name}</value>
        </set-header>
      </inbound>
      <backend>
        <base />
      </backend>
      <outbound>
        <base />
      </outbound>
      <on-error>
        <base />
      </on-error>
    </policies>
  XML

  # The gateway needs the schema to read requests to the API.
  depends_on = [azurerm_api_management_api_schema.graphql]
}

# The storefront's policy also tells the app the path it's published under
# (x-forwarded-prefix), so the links on its pages go through the gateway.
resource "azurerm_api_management_api_policy" "storefront" {
  api_name            = azurerm_api_management_api.storefront.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.main.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <set-backend-service backend-id="${azurerm_api_management_backend.main["storefront"].name}" />
        <set-header name="x-forwarded-by" exists-action="override">
          <value>${azurerm_api_management.main.name}</value>
        </set-header>
        <set-header name="x-forwarded-prefix" exists-action="override">
          <value>/${azurerm_api_management_api.storefront.path}</value>
        </set-header>
      </inbound>
      <backend>
        <base />
      </backend>
      <outbound>
        <base />
      </outbound>
      <on-error>
        <base />
      </on-error>
    </policies>
  XML
}

# ---------------------------------------------------------------------------
# Product - groups the two GraphQL APIs into one offering that a
# subscription grants access to, and applies a rate limit to every
# subscription to it.
# ---------------------------------------------------------------------------
resource "azurerm_api_management_product" "shop" {
  product_id            = "shop"
  display_name          = "Shop"
  description           = "The catalog and orders GraphQL APIs."
  api_management_name   = azurerm_api_management.main.name
  resource_group_name   = azurerm_resource_group.main.name
  subscription_required = true
  approval_required     = false
  published             = true
}

resource "azurerm_api_management_product_api" "shop" {
  for_each = local.graphql_apis

  api_name            = azurerm_api_management_api.graphql[each.key].name
  product_id          = azurerm_api_management_product.shop.product_id
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.main.name
}

# The limit is counted per subscription: each key gets its own allowance, and
# a key that goes over it gets a 429 with a Retry-After header.
resource "azurerm_api_management_product_policy" "shop" {
  product_id          = azurerm_api_management_product.shop.product_id
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.main.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <rate-limit calls="${var.rate_limit_calls}" renewal-period="${var.rate_limit_period}" />
      </inbound>
      <backend>
        <base />
      </backend>
      <outbound>
        <base />
      </outbound>
      <on-error>
        <base />
      </on-error>
    </policies>
  XML
}

# ---------------------------------------------------------------------------
# Subscriptions - the keys sent in the Ocp-Apim-Subscription-Key header,
# both scoped to the Shop product. One is yours, for calling the GraphQL APIs
# yourself; the other is the storefront's, which it calls them with. Each
# has its own rate limit allowance.
# ---------------------------------------------------------------------------
resource "azurerm_api_management_subscription" "shop" {
  display_name        = "Shop example"
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.main.name
  product_id          = azurerm_api_management_product.shop.id
  state               = "active"
}

resource "azurerm_api_management_subscription" "storefront" {
  display_name        = "Storefront"
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.main.name
  product_id          = azurerm_api_management_product.shop.id
  state               = "active"
}
