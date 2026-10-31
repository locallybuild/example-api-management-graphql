# ---------------------------------------------------------------------------
# Log Analytics - for storing both Function Apps' logs
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "main" {
  name                = "${var.name_prefix}-logs"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# ---------------------------------------------------------------------------
# Diagnostic settings - ship each app's function logs into the Log Analytics
# Workspace so they're KQL-queryable in the Monitoring -> Telemetry UI. Within
# the Locally Dashboard these can be queried using:
#   FunctionAppLogs | order by TimeGenerated desc
# ---------------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "function" {
  for_each = local.function_apps

  name                       = "function-logs"
  target_resource_id         = azurerm_linux_function_app.main[each.key].id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "FunctionAppLogs"
  }
}
