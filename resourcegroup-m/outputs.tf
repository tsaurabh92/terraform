output "resourcegrp_id" {
    value = azurerm_resource_group.resourcegrp.id
  
}

output "resourcegrp_name" {
    value = azurerm_resource_group.resourcegrp.name
    description = "Resource Group Name"
  
}

output "resourcegrp_location" {
    value = azurerm_resource_group.resourcegrp.location
  
}