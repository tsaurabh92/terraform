# Custom security rules
# [priority, direction, access, protocol, source_port_range, destination_port_range, description]"
# All the fields are required.
variable "custom_rules" {
  description = "Security rules for the network security group using this format name = [priority, direction, access, protocol, source_port_range, destination_port_range, source_address_prefix, destination_address_prefix, description]"
  type        = any
  default     = []
}

variable "rg_grp_name" {
  type = string
  description = "Name of the resource group"
  
}

variable "custom_security_rules" {

  description = "Default NSG Rules"
  default = []
  
}

variable "default_security_rules" {
  description = "Default Firewall rules for NSG"
  
}

variable "sg_location" {
  description = "Location for Security Group"
  
}

variable "service_name" {
  description = "Allowed Values are Virtual Machine and Subnet"
  type = map(string)

  default = {
    "Virtual Machine" = "vm"
    "Subnet" = "sn"
  }



  
}

variable "sg_name" {
  type = string
  description = "Security Group Name"
  default = "nsg"
  
}