# Base image for all VMs
resource "libvirt_volume" "base_image" {
  name   = "debian-12-generic-amd64.qcow2"
  pool   = "default"
  source = var.base_image_path
  format = "qcow2"
}

# Swarm VMs disks
resource "libvirt_volume" "swarm" {
  count          = var.swarm_nodes
  name           = "stremio-beamup-swarm-${count.index}.qcow2"
  pool           = "default"
  base_volume_id = libvirt_volume.base_image.id
  size           = var.swarm_disk_size
}

# The swarm servers
resource "libvirt_domain" "swarm" {
  count  = var.swarm_nodes
  name   = "stremio-beamup-swarm-${count.index}"
  memory = var.swarm_memory
  vcpu   = var.swarm_vcpu

  cloudinit = libvirt_cloudinit_disk.commoninit.id

  network_interface {
    network_name   = var.network_name
    wait_for_lease = true
  }

  disk {
    volume_id = libvirt_volume.swarm[count.index].id
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  console {
    type        = "pty"
    target_type = "virtio"
    target_port = "1"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }
}

resource "ansible_host" "swarm_host" {
  depends_on = [libvirt_domain.swarm]

  count = var.swarm_nodes # Same count as your server instances

  #name   = "stremio-beamup-swarm-${count.index}"
  name   = "${local.swarm_public_ips[count.index]}"
  groups = ["swarm","swarm_${count.index}"]

  variables = {
    greetings   = "Hello from swarm node ${count.index}!"
    hostname    = local.swarm_hostnames[count.index]
#    public_ip   = local.swarm_public_ips[count.index]
#    private_ip  = local.swarm_private_ips[count.index]
    # Additional variables can be added here
  }
}

resource "null_resource" "swarm_apt_update" {
  depends_on = [ansible_host.swarm_host]

  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} --limit swarm ${var.project_dir}/ansible/playbooks/apt_update.yml"
    environment = {
      TF_STATE = "./"
    }
  }
}

resource "null_resource" "swarm_initial_setup" {
  count = var.swarm_nodes

  depends_on = [null_resource.swarm_apt_update]

  provisioner "local-exec" {
    command = "ansible -m hostname -b  -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} -a \"name=stremio-beamup-swarm-${count.index}\" swarm_${count.index}"

    environment = {
      TF_STATE = "./"
    }
  }

  provisioner "local-exec" {
    command = "ansible -m lineinfile -b  -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} -a \"dest=/etc/hosts line='127.0.1.1 stremio-beamup-swarm-${count.index}'\" swarm_${count.index}"

    environment = {
      TF_STATE = "./"
    }
  }
}

resource "null_resource" "swarm_install_docker" {
  depends_on = [null_resource.swarm_initial_setup]

  provisioner "local-exec" {
    command = "echo 'Waiting for setup scripts to finish...' && sleep 60"
  }

  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${var.project_dir}/ansible/playbooks/docker.yml"

    environment = {
      TF_STATE = "./"
    }
  }
}

resource "null_resource" "swarm_os_setup" {
  depends_on = [null_resource.swarm_install_docker]

  #
  # Install packages
  #
  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${var.project_dir}/ansible/playbooks/swarm_apt.yml"

    environment = {
      TF_STATE = "./"
    }
  }

  #
  # Fine tune some sysctl values
  #
  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${var.project_dir}/ansible/playbooks/swarm_os.yml"

    environment = {
      TF_STATE = "./"
    }
  }

  #
  # Init the swarm on the first server
  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${var.project_dir}/ansible/playbooks/swarm_0_init.yml"

    environment = {
      TF_STATE = "./"
    }
  }
}

# TODO
# Use docker_swarm ansible module
resource "null_resource" "swarm_docker_join" {
  depends_on = [null_resource.swarm_os_setup, data.external.swarm_tokens]
  count      = var.swarm_nodes > 1 ? var.swarm_nodes - 1 : 0

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file(var.private_key)
    host        = local.swarm_public_ips[count.index + 1]
  }

  provisioner "remote-exec" {
    inline = [
      var.swarm_nodes - 1 > 0 ? format("docker swarm join --token %s %s:2377", data.external.swarm_tokens.result.manager, local.swarm_manager_private_ip[1].address) : "echo skipping..."
    ]
  }
}

resource "null_resource" "swarm_docker_setup" {
  depends_on = [null_resource.swarm_docker_join, null_resource.swarm_initial_setup]

  #
  # Run setup for swarm_0
  #
  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} --extra-vars 'domain=${var.domain}' ${var.project_dir}/ansible/playbooks/swarm_0_setup.yml"

    environment = {
      TF_STATE = "./"
    }
  }

  #
  # Copy beamup swarm setup script & execute
  #
  provisioner "local-exec" {
    command = "ansible -T 30 -u root -m copy -a 'src=${var.project_dir}/swarm-syncer/beamup-sync-and-deploy dest=/usr/local/bin/ mode=0755' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm"

    environment = {
      TF_STATE = "./"
    }
  }

  provisioner "local-exec" {
    command = "ansible -T 30 -u root -m copy -a 'src=${var.project_dir}/swarm-syncer/beamup-sync-swarm dest=/usr/local/bin/ mode=0755' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm"

    environment = {
      TF_STATE = "./"
    }
  }

  provisioner "local-exec" {
    command = "ansible -T 30 -u root -m shell -a '/usr/local/bin/beamup-sync-and-deploy' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm"

    environment = {
      TF_STATE = "./"
    }
  }
}

resource "null_resource" "swarm_deployer_script" {
  depends_on = [null_resource.deployer_tunnel_setup, data.template_file.beamup_sync_swarm]

  provisioner "local-exec" {
    command = format("cat <<\"EOF\" > \"%s\"\n%s\nEOF", "beamup-sync-swarm.sh", data.template_file.beamup_sync_swarm.rendered)
  }

  provisioner "local-exec" {
    command = "ansible -T 30 -b -u ${var.username} -m copy -a 'src=${var.deployer_key}.pub dest=/home/${var.username}/.ssh/ mode=0600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm_0"

    environment = {
      TF_STATE = "./"
    }
  }

  provisioner "local-exec" {
    command = "ansible -T 30 -u ${var.username} -m copy -a 'src=beamup-sync-swarm.sh dest=/home/${var.username}/beamup-sync-swarm.sh mode=0755' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm_0"

    environment = {
      TF_STATE = "./"
    }
  }

  provisioner "local-exec" {
    command = format("ansible -T 30 -u ${var.username} -m shell -a 'echo \"command=\\\"beamup-swarm-entry \\$SSH_ORIGINAL_COMMAND\\\",restrict %s\" >> /home/${var.username}/.ssh/authorized_keys' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm", file("${var.project_dir}/${var.deployer_key}.pub"))

    environment = {
      TF_STATE = "./"
    }
  }

  provisioner "local-exec" {
    command = "ansible -m lineinfile -b -u ${var.username} --ssh-extra-args='-o StrictHostKeyChecking=no' -a \"dest=/etc/sudoers regexp='^(.*)beamup(.*)' line='beamup ALL=(ALL) NOPASSWD: /bin/systemctl restart nginx'\" --inventory=${var.terraform_inventory_path} swarm"

    environment = {
      TF_STATE = "./"
    }
  }
}