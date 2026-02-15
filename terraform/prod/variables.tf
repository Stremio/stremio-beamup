variable "project_dir" {
  description = "The path to the main project directory"
  type        = string
  default     = "./../.."
}

variable "private_key" {
  description = "Path to the private SSH key"
  type        = string
  default     = "./../../id_deploy"
}

variable "public_keys" {
  description = "Path to the authorized_keys file"
  type        = string
  default     = "./../../authorized_keys"
}

variable "deployer_key" {
  description = "Path to the deployer's private SSH key"
  type        = string
  default     = "./../../id_ed25519_deployer_sync"
}

variable "deployer_tunnel_key" {
  description = "Path to the deployer tunnel private SSH key"
  type        = string
  default     = "./../../id_ed25519_deployer_tunnel"
}

variable "terraform_inventory_path" {
  description = "The path to the terraform-inventory"
  type        = string
  #default     = "/usr/local/bin/terraform-inventory"
  default = "./../../inventory.yml"
}

variable "region" {
  default = "eu_nord_1"
}

variable "image" {
  default = "debian_12_64bit"
}

variable "domain" {
  default = "beamup.dev"
}

variable "swarm_nodes" {
  default = 1
}

#https://docs.ansible.com/ansible/latest/reference_appendices/faq.html#how-do-i-generate-encrypted-passwords-for-the-user-module
variable "user_password_hash" {
  description = "The password for the OS user in SHA512"
  type        = string
}

# About plans
# Smart Servers are not supported anymore, like id 94 for ssd_smart16
# Virtual Servers no longer have Debian 10 and that is needed for Dokku v0.20.
variable "deployer_plan_slug" {
  default = "cloud_vds_2"
}

variable "swarm_plan_slug" {
  default = "cloud_vps_6"
}

variable "username" {
  default = "beamup"
}

variable "deployment_environment" {
  description = "The environment this infrastructure should be associated with, like stating, development, etc."
  type        = string
  default     = "production"
}

variable "first_interface" {
  description = "This should be the name of the interface that has the Public IP and allows access to Internet"
  type        = string
  default     = "eth0"
}
