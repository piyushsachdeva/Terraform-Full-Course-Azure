terraform {
  backend "azurerm" {
    resource_group_name  = "terraform-state-rg"
    storage_account_name = "tfdevbackend2024piyush"
    container_name      = "tfstate"
    key                 = "dev.tfstate"
  }
}

provider "azurerm" {
  features {}
}