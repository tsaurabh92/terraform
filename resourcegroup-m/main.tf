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

resource "azurerm_resource_group" "resourcegrp" {
location = var.location
name = "${var.rgprefix}${var.resourcegroupName}"
tags = {
  "Createdby" = "Terraform"
}
  
}