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

variable "terraform_inventory_path" {
  description = "The path to the terraform-inventory"
  type        = string
  #default     = "/usr/local/bin/terraform-inventory"
  default     = "./../../inventory.yml"
}

variable "domain" {
  description = "Domain name for the deployment"
  type        = string
  default     = "beamup.dev"
}

variable "swarm_nodes" {
  description = "Number of swarm nodes to create"
  type        = number
  default     = 1
}

# https://docs.ansible.com/ansible/latest/reference_appendices/faq.html#how-do-i-generate-encrypted-passwords-for-the-user-module
variable "user_password_hash" {
  description = "The password for the OS user in SHA512"
  type        = string
}

variable "username" {
  description = "Username for the system user"
  type        = string
  default     = "beamup"
}

variable "deployment_environment" {
  description = "The environment this infrastructure should be associated with, like staging, development, etc."
  type        = string
  default     = "production"
}

variable "first_interface" {
  description = "This should be the name of the interface that has the Public IP and allows access to Internet"
  type        = string
  default     = "enp1s0"
}

# Libvirt specific variables
variable "libvirt_uri" {
  description = "Libvirt connection URI"
  type        = string
  default     = "qemu:///system"
}

variable "base_image_path" {
  description = "Path to the base OS image (qcow2)"
  type        = string
  default     = "/var/lib/libvirt/images/debian-12-generic-amd64.qcow2"
}

variable "network_name" {
  description = "Libvirt network to attach VMs to"
  type        = string
  default     = "default"
}

variable "deployer_memory" {
  description = "Memory for deployer VM in MB"
  type        = number
  default     = 2048
}

variable "deployer_vcpu" {
  description = "Number of vCPUs for deployer VM"
  type        = number
  default     = 2
}

variable "deployer_disk_size" {
  description = "Disk size for deployer VM in bytes"
  type        = number
  default     = 21474836480  # 20GB
}

variable "swarm_memory" {
  description = "Memory for swarm VMs in MB"
  type        = number
  default     = 4096
}

variable "swarm_vcpu" {
  description = "Number of vCPUs for swarm VMs"
  type        = number
  default     = 2
}

variable "swarm_disk_size" {
  description = "Disk size for swarm VMs in bytes"
  type        = number
  default     = 32212254720  # 30GB
}