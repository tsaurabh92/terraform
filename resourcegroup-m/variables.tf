variable "resourcegroupName" {
    type = string
    description = "Name of the resource group"

  
}

variable "location" {
    type = string
    description = "Location for RM Ressources"
    default = "eastus"

    validation {
      condition = var.location == "eastus"
      error_message = "You are not creating resource in East US"
    }
  
}

variable "rgprefix" {
  type = string
  default = "rg-"

  }