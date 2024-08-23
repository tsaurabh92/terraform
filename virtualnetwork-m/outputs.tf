output "subnet_names" {
    value = {for k, v in azurerm_subnet.prod_subnets : k=> v.name }
  
}