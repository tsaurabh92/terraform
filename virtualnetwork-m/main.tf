terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = "3.114.0"
    }
  }
}

provider "azurerm" {
    features {}

}
module "resource_grp_name" {
    source = "../resourcegroup-m"
    resourcegroupName = var.rgname
    location = var.location
    
}

resource "azurerm_virtual_network" "azvnet" {
  address_space = var.address_space
  name = "${var.vnet_name}${module.resource_grp_name.resourcegrp_location}"
  resource_group_name = module.resource_grp_name.resourcegrp_name
  location = module.resource_grp_name.resourcegrp_location
}

resource "azurerm_subnet" "prod_subnets" {
  
  for_each = var.subnets
  name = each.value.name
  address_prefixes = [each.value.address_prefix]
  virtual_network_name = azurerm_virtual_network.azvnet.name
  resource_group_name = module.resource_grp_name.resourcegrp_name
  
  
}