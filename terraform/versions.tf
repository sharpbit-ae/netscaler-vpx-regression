terraform {
  required_version = ">= 1.3"

  required_providers {
    citrixadc = {
      source  = "citrix/citrixadc"
      version = "~> 1.45"
    }
  }
}
