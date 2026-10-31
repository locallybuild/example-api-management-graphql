output "gateway_url" {
  description = "The API Management gateway's base URL."
  value       = module.api-management-graphql.gateway_url
}

output "catalog_url" {
  description = "The catalog GraphQL API's endpoint, through the gateway."
  value       = module.api-management-graphql.catalog_url
}

output "orders_url" {
  description = "The orders GraphQL API's endpoint, through the gateway."
  value       = module.api-management-graphql.orders_url
}

output "storefront_url" {
  description = "The storefront's pages, through the gateway. Open it in a browser."
  value       = module.api-management-graphql.storefront_url
}

output "subscription_key" {
  description = "The Shop subscription's primary key, sent as the Ocp-Apim-Subscription-Key header."
  value       = module.api-management-graphql.subscription_key
  sensitive   = true
}

output "app_urls" {
  description = "Each app's own URL, which refuses calls that don't carry the app's credential."
  value       = module.api-management-graphql.app_urls
}

output "api_management_name" {
  description = "The name of the API Management instance."
  value       = module.api-management-graphql.api_management_name
}
