variable "name_prefix" {
  description = "The prefix used for all resources in this example."
  type        = string
}

variable "location" {
  description = "The region where these resources should be deployed."
  type        = string
}

variable "tags" {
  description = "A mapping of tags which should be applied to each of the resources."
  type        = map(string)
  default     = {}
}

variable "service_plan_sku" {
  description = "App Service plan SKU (Linux), shared by the Function Apps and the Web App."
  type        = string
  default     = "B1"
}

variable "publisher_name" {
  description = "The publisher name shown on the API Management instance."
  type        = string
  default     = "Locally Example"
}

variable "publisher_email" {
  description = "The publisher email on the API Management instance."
  type        = string
  default     = "apis@example.com"
}

variable "rate_limit_calls" {
  description = "How many calls each subscription to the Shop product may make per rate limit period."
  type        = number
  default     = 20
}

variable "rate_limit_period" {
  description = "The rate limit period, in seconds."
  type        = number
  default     = 60
}
