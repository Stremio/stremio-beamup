terraform {
  required_version = ">= 1.8"

  required_providers {
    cherryservers = {
      source  = "cherryservers/cherryservers"
      version = "~> 0.0.6"
    }
    #    cherryservers = {
    #      source  = "terraform.local/local/cherryservers"
    #      version = "1.0.0"
    #    }
    ansible = {
      version = "~> 1.3.0"
      source  = "ansible/ansible"
    }
  }

}

provider "cherryservers" {
  api_token = trimspace(file("${var.project_dir}/creds/cherryservers"))
}
