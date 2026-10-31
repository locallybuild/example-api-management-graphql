output "gateway_url" {
  description = "The API Management gateway's base URL."
  value       = azurerm_api_management.main.gateway_url
}

output "catalog_url" {
  description = "The catalog GraphQL API's endpoint, through the gateway."
  value       = "${azurerm_api_management.main.gateway_url}/${azurerm_api_management_api.graphql["catalog"].path}"
}

output "orders_url" {
  description = "The orders GraphQL API's endpoint, through the gateway."
  value       = "${azurerm_api_management.main.gateway_url}/${azurerm_api_management_api.graphql["orders"].path}"
}

output "storefront_url" {
  description = "The storefront's pages, through the gateway. Open it in a browser."
  value       = "${azurerm_api_management.main.gateway_url}/${azurerm_api_management_api.storefront.path}/"
}

output "subscription_key" {
  description = "The Shop subscription's primary key, sent as the Ocp-Apim-Subscription-Key header."
  value       = azurerm_api_management_subscription.shop.primary_key
  sensitive   = true
}

output "app_urls" {
  description = "Each app's own URL, which refuses calls that don't carry the app's credential."
  value = {
    catalog    = "https://${azurerm_linux_function_app.main["catalog"].default_hostname}/api/graphql"
    orders     = "https://${azurerm_linux_function_app.main["orders"].default_hostname}/api/graphql"
    storefront = "https://${azurerm_linux_web_app.storefront.default_hostname}"
  }
}

output "api_management_name" {
  description = "The name of the API Management instance."
  value       = azurerm_api_management.main.name
}

output "resource_group" {
  description = "The resource group containing the deployed resources."
  value       = azurerm_resource_group.main.name
}
