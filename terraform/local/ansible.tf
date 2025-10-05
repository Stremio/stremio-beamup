resource "null_resource" "ansible_beamup_users" {
  depends_on = [null_resource.swarm_docker_setup, null_resource.deployer_setup]

  provisioner "local-exec" {
    command = "ansible -T 30 -u root -m apt -a 'name=sudo state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm"

    environment = {
      TF_STATE = "./"
    }
  }

  provisioner "local-exec" {
    command = "ansible-playbook -b -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --extra-vars 'username=${var.username}' --extra-vars 'user_pubkey=${format("%s/%s", data.external.workdir.result.workdir, var.public_keys)}' --extra-vars 'password_hash=${var.user_password_hash}' --inventory=${var.terraform_inventory_path} ${var.project_dir}/ansible/playbooks/users.yml"

    environment = {
      TF_STATE = "./"
    }
  }

  # XXX: ensure sudo does not ask for password
  provisioner "local-exec" {
    command = "ansible -m lineinfile -b  -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} -a \"dest=/etc/sudoers regexp='^(.*)%sudo(.*)' line='%sudo ALL=(ALL:ALL) NOPASSWD:ALL'\" all"

    environment = {
      TF_STATE = "./"
    }
  }
}

#
# After creating this resource, root access via SSH is forbidden; login as user 'beamup'/the configured default user instead
#
resource "null_resource" "swarm_ansible_configure_ssh" {
  depends_on = [null_resource.ansible_beamup_users]

  provisioner "local-exec" {
    command = "ansible-playbook -b -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${var.project_dir}/ansible/playbooks/swarm_nodes_setup.yml"

    environment = {
      TF_STATE = "./"
    }
  }
}

resource "null_resource" "ansible_configure_ssh" {
  depends_on = [null_resource.swarm_ansible_configure_ssh]

  provisioner "local-exec" {
    command = "ansible -m lineinfile -b  -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} -a \"dest=/etc/hosts line='${local.deployer_public_ip} ${local.deployer_hostname}'\" all"

    environment = {
      TF_STATE = "./"
    }
  }

  provisioner "local-exec" {
    command = "ansible-playbook -b -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --extra-vars 'sshd_config=${var.project_dir}/ansible/files/sshd_config' --extra-vars 'banner=${format("%s/ansible/files/banner", var.project_dir)}' --inventory=${var.terraform_inventory_path} ${var.project_dir}/ansible/playbooks/sshd.yml"

    environment = {
      TF_STATE = "./"
    }
  }
}

resource "null_resource" "ansible_configure_cron" {
  depends_on = [
    null_resource.ansible_configure_ssh,
  ]

  provisioner "local-exec" {
    command = "ansible-playbook -b -u ${var.username} --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${var.project_dir}/ansible/playbooks/cron.yml"

    environment = {
      TF_STATE = "./"
    }
  }
}

resource "null_resource" "ansible_swarm_setup_nginx" {
  depends_on = [
    null_resource.ansible_configure_ssh,
  ]

  provisioner "local-exec" {
    command = "ansible-playbook -b -u ${var.username} --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} --extra-vars 'username=${var.username}' ${var.project_dir}/ansible/playbooks/swarm_nginx.yml"

    environment = {
      TF_STATE = "./"
    }
  }
}

resource "null_resource" "ansible_os_tuning" {
  depends_on = [
    null_resource.ansible_configure_ssh,
  ]

  # Tuning limits for user dokku
  provisioner "local-exec" {
    command = "ansible-playbook -b -u ${var.username} --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${var.project_dir}/ansible/playbooks/os_tuning.yml -e user=dokku --limit deployer"

    environment = {
      TF_STATE = "./"
    }
  }

  # Tuning limits for user www-data for nginx only on first swarm node (balancer)
  provisioner "local-exec" {
    command = "ansible-playbook -b -u ${var.username} --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${var.project_dir}/ansible/playbooks/os_tuning.yml -e user=www-data --limit swarm_0"

    environment = {
      TF_STATE = "./"
    }
  }
}

resource "null_resource" "ansible_swarm_disable_swap" {
  depends_on = [
    null_resource.ansible_configure_ssh,
  ]

  provisioner "local-exec" {
    command = "ansible-playbook -b -u ${var.username} --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${var.project_dir}/ansible/playbooks/disable-swap.yml"

    environment = {
      TF_STATE = "./"
    }
  }
}

resource "null_resource" "hosts_firewall" {
  depends_on = [null_resource.deployer_tunnel_setup, null_resource.swarm_deployer_script]

  provisioner "local-exec" {
    command = "ansible -T 30 -b -u ${var.username} -m apt -a 'name=iptables-persistent state=present update_cache=yes' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} all"

    environment = {
      TF_STATE = "./"
    }
  }

  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -b -u ${var.username} --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} --extra-vars 'first_interface=${var.first_interface}' ${var.project_dir}/ansible/playbooks/iptables.yml"

    environment = {
      TF_STATE = "./"
    }
  }
}