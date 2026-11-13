terraform {
  required_version = ">= 1.5.0"
  required_providers {
    hyperv = {
      source  = "taliesins/hyperv"
      version = "~> 1.2"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}
