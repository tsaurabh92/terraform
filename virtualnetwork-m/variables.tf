variable "address_space" {
  type        = list(string)
  default = [ "10.112.144.0/21" ]
  description = "The address space that is used by the virtual network."
}

variable "rgname" {
    type = string
    description = "Name of the Resource Group to be Created"
  
}

variable "location" {
    type = string
    description = "location for vnet module"
  
}

variable "vnet_name" {
  type        = string
  default     = "acctvnet"
  description = "Name of the vnet to create"
}

/*variable "subnet_name_Prefix" {
  
  type = map(string)
  
  default = {

    "db-subnet" = "10.112.144.0/27",
    "web-subnet" =  "10.112.144.32/27",
    "app-subnet" = "10.112.144.64/27"
  }
    
    }*/



/*variable "subnet_prefixes" {
  type = list(string)
  default = ["10.112.144.0/27","10.112.144.32/27","10.112.144.64/27"]
}*/

variable "subnets" {
  type = map(object({
    name          = string
    address_prefix = string
  }))

  default = {
    subnet1 = {
      name          = "db-subnet"
      address_prefix = "10.112.144.0/27"
    }
    subnet2 = {
      name          = "web-subnet"
      address_prefix = "10.112.144.32/27"
    }
    subnet3={
      name = "app-subnet"
      address_prefix = "10.112.144.64/27"


    }
  }
}
