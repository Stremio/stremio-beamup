# Deployer VM disk
resource "libvirt_volume" "deployer" {
  name           = "stremio-addon-deployer.qcow2"
  pool           = "default"
  base_volume_id = libvirt_volume.base_image.id
  size           = var.deployer_disk_size
}

# The controller/deployer server
resource "libvirt_domain" "deployer" {
  name   = "stremio-addon-deployer"
  memory = var.deployer_memory
  vcpu   = var.deployer_vcpu

  cloudinit = libvirt_cloudinit_disk.commoninit.id

  network_interface {
    network_name   = var.network_name
    wait_for_lease = true
  }

  disk {
    volume_id = libvirt_volume.deployer.id
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

resource "ansible_host" "deployer" {
  depends_on = [libvirt_domain.deployer]

  name   = local.deployer_public_ip
  groups = ["deployer"]

  variables = {
    greetings   = "from deployer!"
    some        = "variable"
  }
}

resource "null_resource" "deployer_apt_update" {
  depends_on = [ansible_host.deployer]

  provisioner "local-exec" {
    command = "echo 'Waiting for cloud-init to finish...' && sleep 60"
  }

  provisioner "local-exec" {
    command = "ansible-galaxy install -f -r ${var.project_dir}/ansible/requirements.yml"
  }

  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} --limit deployer ${var.project_dir}/ansible/playbooks/apt_update.yml"
    environment = {
      TF_STATE = "./"
    }
  }
}

resource "null_resource" "deployer_setup" {
  depends_on = [null_resource.deployer_apt_update]

  provisioner "local-exec" {
    command = "echo 'Waiting for setup scripts to finish...' && sleep 60"
  }

  provisioner "local-exec" {
    command = "ansible -m hostname -b  -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} -a \"name=stremio-addon-deployer\" deployer"

    environment = {
      TF_STATE = "./"
    }
  }

  provisioner "local-exec" {
    command = "ansible -m lineinfile -b  -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} -a \"dest=/etc/hosts line='127.0.1.1 stremio-addon-deployer'\" deployer"

    environment = {
      TF_STATE = "./"
    }
  }

  #
  # Install packages
  #
  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${var.project_dir}/ansible/playbooks/deployer_apt.yml"

    environment = {
      TF_STATE = "./"
    }
  }

  #
  # Prepare SSH key for swarm sync
  #
  provisioner "local-exec" {
    command = "rm -f ${var.deployer_key} && rm -f ${var.deployer_key}.pub && ssh-keygen -t ed25519 -f ${var.deployer_key} -C 'dokku@stremio-addon-deployer' -q -N ''"
  }

  #
  # Run setup
  #
  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} --extra-vars 'domain=${var.domain}' ${var.project_dir}/ansible/playbooks/deployer_setup.yml"

    environment = {
      TF_STATE = "./"
    }
  }
}

resource "null_resource" "deployer_tunnel_setup" {
  depends_on = [data.template_file.ssh_tunnel_service, null_resource.ansible_swarm_disable_swap]

  provisioner "local-exec" {
    command = "rm -f ${var.deployer_tunnel_key} && rm -f ${var.deployer_tunnel_key}.pub && ssh-keygen -t ed25519 -f ${var.deployer_tunnel_key} -C 'dokku@stremio-addon-deployer' -q -N ''"
  }

  provisioner "local-exec" {
    command = format("cat <<\"EOF\" > \"%s\"\n%s\nEOF", "../../secure-tunnel-swarm.service", data.template_file.ssh_tunnel_service.rendered)
  }

  provisioner "local-exec" {
    command = "ansible -T 30 -b -u ${var.username} -m copy -a 'src=${var.deployer_tunnel_key}.pub dest=/home/${var.username}/.ssh/ mode=0600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm_0"

    environment = {
      TF_STATE = "./"
    }
  }

  # TODO
  # Check this resource and specially this next provisioner as it looks like it is not required.
  provisioner "local-exec" {
    command = "ansible -T 30 -b -u ${var.username} -m shell -a 'echo -n command=\"beamup-sync-and-deploy\",restrict,permitopen=\"localhost:5000\" && cat /home/${var.username}/.ssh/id_ed25519_deployer_tunnel.pub >> /home/${var.username}/.ssh/authorized_keys' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm_0"

    environment = {
      TF_STATE = "./"
    }
  }

  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -b -u ${var.username} --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} --extra-vars 'username=${var.username}' ${var.project_dir}/ansible/playbooks/deployer_tunnel.yml"

    environment = {
      TF_STATE = "./"
    }
  }
}