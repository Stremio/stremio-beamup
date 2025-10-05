terraform {
  required_version = ">= 1.8"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.7.0"
    }
    ansible = {
      version = "~> 1.3.0"
      source  = "ansible/ansible"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

# Cloud-init configuration for SSH key injection
resource "libvirt_cloudinit_disk" "commoninit" {
  name      = "commoninit.iso"
  user_data = data.template_file.user_data.rendered
}



# Local values for computed resources
# This creates an abstraction layer between provider-specific resources
# and the rest of the configuration

locals {
  # Deployer server information
  deployer_hostname    = libvirt_domain.deployer.name
  deployer_public_ip   = libvirt_domain.deployer.network_interface[0].addresses[0]
  deployer_private_ip  = null  # libvirt typically uses single interface
  
  # Swarm server information
  swarm_hostnames     = [for server in libvirt_domain.swarm : server.name]
  swarm_public_ips    = [for server in libvirt_domain.swarm : server.network_interface[0].addresses[0]]
  swarm_private_ips   = [for i in range(var.swarm_nodes) : null]  # single interface setup
  
  # First swarm node (swarm manager)
  swarm_manager_hostname   = length(libvirt_domain.swarm) > 0 ? libvirt_domain.swarm[0].name : ""
  swarm_manager_public_ip  = length(libvirt_domain.swarm) > 0 ? libvirt_domain.swarm[0].network_interface[0].addresses[0] : ""
  swarm_manager_private_ip = ""  # single interface setup
  
  # SSH configuration
  ssh_args = "-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
  
  # Ansible inventory and environment
  ansible_env = {
    TF_STATE = "./"
  }
  
  # Common ansible command prefixes
  ansible_base_cmd     = "ansible -T 30 --ssh-extra-args='${local.ssh_args}' --inventory=${var.terraform_inventory_path}"
  ansible_playbook_cmd = "ansible-playbook -T 30 --ssh-extra-args='${local.ssh_args}' --inventory=${var.terraform_inventory_path}"
  
  # File paths
  workdir = data.external.workdir.result.workdir
  
  # Generated files
  sync_script_content    = data.template_file.beamup_sync_swarm.rendered
  tunnel_service_content = data.template_file.ssh_tunnel_service.rendered
}