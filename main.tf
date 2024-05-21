terraform {
  required_version = ">= 0.12"

  required_providers {
    cherryservers = {
      source  = "terraform.local/local/cherryservers"
      version = "1.0.0"
    }
#    ansible = {
#      version = "~> 1.2.0"
#      source  = "ansible/ansible"
#    }
  }

}


# Variables

provider "cherryservers" {
  auth_token = trimspace(file("./creds/cherryservers"))
}

variable "private_key" {
  default = "./id_deploy"
}

variable "public_keys" {
  default = "authorized_keys"
}

variable "terraform_inventory_path" {
  description = "The path to the terraform-inventory binary"
  type        = string
  default     = "/usr/local/bin/terraform-inventory"
}

variable "region" {
  default = "EU-Nord-1"
}

variable "image" {
  default = "Debian 12 64bit"
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
# @TODO Update Dokku so new versions of Debian can be used and VDS from CherryServers too
# Working plans are Dedicated Servers like:
# E3-1240v3 is 86
# E3-1240V5 is 113
# E5-1650V2 is 106 
variable "deployer_plan_id" {
  default = "86"
}

variable "swarm_plan_id" {
  default = "113"
}

variable "username" {
  default = "beamup"
}

variable "deployment_environment" {
  description = "The environment this infrastructure should be associated with, like stating, development, etc."
  type        = string
  default     = "production"
}

# Resources

## Execute a local command to log the public_key value
#resource "null_resource" "log_public_key" {
#  triggers = {
#    always_run = "${timestamp()}"
#  }
#
#  provisioner "local-exec" {
#    command = "echo ${file("${var.private_key}.pub")}"
#  }
#}

resource "cherryservers_ssh" "tf_deploy_key" {
  name       = "tf_deploy_key_${var.deployment_environment}"
#https://github.com/hashicorp/terraform/issues/7531
  public_key = "${replace(file("${var.private_key}.pub"), "\n", "")}"
}

# The controller/deployer server
resource "cherryservers_server" "deployer" {
  project_id   = trimspace(file("./creds/cherryservers_project_id"))
  region       = var.region
  hostname     = "stremio-addon-deployer"
  image        = var.image
  plan_id      = var.deployer_plan_id
  ssh_keys_ids = [cherryservers_ssh.tf_deploy_key.id]
  tags = {
    Name        = "stremio-addon-deployer"
    Project     = "beamup"
    Environment = var.deployment_environment
  }
}

resource "null_resource" "deployer_apt_update" {
  depends_on = [cherryservers_server.deployer]

  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} --limit deployer ${path.cwd}/ansible/playbooks/apt_update.yml"
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
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${path.cwd}/ansible/playbooks/deployer_apt.yml"

    environment = {
      TF_STATE = "./"
    }
  }

  #
  # Prepare SSH key for swarm sync
  #
  provisioner "local-exec" {
    command = "rm -f id_ed25519_deployer_sync && rm -f id_ed25519_deployer_sync.pub && ssh-keygen -t ed25519 -f id_ed25519_deployer_sync -C 'dokku@stremio-addon-deployer' -q -N ''"
  }

  #
  # Run setup
  #
  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} --extra-vars 'domain=${var.domain}' ${path.cwd}/ansible/playbooks/deployer_setup.yml"

    environment = {
      TF_STATE = "./"
    }
  }
}

# The swarm servers
# TODO: add deployer in authorized-keys
resource "cherryservers_server" "swarm" {
  count      = var.swarm_nodes
  project_id = trimspace(file("./creds/cherryservers_project_id"))
  region     = var.region
  hostname   = "stremio-beamup-swarm-${count.index}"
  image      = var.image
  plan_id      = var.swarm_plan_id
  ssh_keys_ids = [cherryservers_ssh.tf_deploy_key.id]
  tags = {
    Name        = "stremio-beamup-swarm-${count.index}"
    Project     = "beamup"
    Environment = var.deployment_environment
  }
}

resource "null_resource" "swarm_apt_update" {
  depends_on = [cherryservers_server.swarm]

  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} --limit swarm ${path.cwd}/ansible/playbooks/apt_update.yml"
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
    command = "ansible-galaxy install -f geerlingguy.docker"
  }

  provisioner "local-exec" {
    command = "ansible-galaxy install -f geerlingguy.pip"
  }

  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${path.cwd}/ansible/playbooks/docker.yml"

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
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${path.cwd}/ansible/playbooks/swarm_apt.yml"

    environment = {
      TF_STATE = "./"
    }
  }

  #
  # Fine tune some sysctl values
  #
  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${path.cwd}/ansible/playbooks/swarm_os.yml"

    environment = {
      TF_STATE = "./"
    }
  }

  #
  # Init the swarm on the first server
  provisioner "local-exec" {
    command = "ansible -T 30 -u root -m community.docker.docker_swarm -a 'state=present subnet_size=16 advertise_addr=ens4' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm_0"

    environment = {
      TF_STATE = "./"
    }
  }

}

data "external" "swarm_tokens" {
  program = ["${path.cwd}/scripts/fetch-tokens.sh"]

  query = {
    host        = "${cherryservers_server.swarm.0.primary_ip}"
    private_key = "${var.private_key}"
  }

  depends_on = [null_resource.swarm_os_setup]

}

data "external" "workdir" {
  program = ["${path.cwd}/scripts/fetch-workdir.sh"]
}

#TODO
#Use docker_swarm ansible module
resource "null_resource" "swarm_docker_join" {
  depends_on = [null_resource.swarm_os_setup, data.external.swarm_tokens]
  count      = var.swarm_nodes > 1 ? var.swarm_nodes - 1 : 0

  connection {
    private_key = file(var.private_key)
    host        = element(cherryservers_server.swarm.*.primary_ip, count.index + 1)
  }

  provisioner "remote-exec" {
    inline = [
      "${var.swarm_nodes - 1 > 0 ? format("docker swarm join --token %s %s:2377", data.external.swarm_tokens.result.manager, cherryservers_server.swarm.0.private_ip) : "echo skipping..."}"
    ]
  }
}

resource "null_resource" "swarm_docker_setup" {
  depends_on = [null_resource.swarm_docker_join, null_resource.swarm_initial_setup]

  #
  # Run setup for swarm_0
  #
  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} --extra-vars 'domain=${var.domain}' ${path.cwd}/ansible/playbooks/swarm_0_setup.yml"

    environment = {
      TF_STATE = "./"
    }
  }

  #
  # Copy beamup swarm setup script & execute
  #
  provisioner "local-exec" {
    command = "ansible -T 30 -u root -m copy -a 'src=swarm-syncer/beamup-sync-and-deploy dest=/usr/local/bin/ mode=0755' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm"

    environment = {
      TF_STATE = "./"
    }
  }

  provisioner "local-exec" {
    command = "ansible -T 30 -u root -m copy -a 'src=swarm-syncer/beamup-sync-swarm dest=/usr/local/bin/ mode=0755' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm"

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

resource "null_resource" "ansible_beamup_users" {
  depends_on = [null_resource.swarm_docker_setup, null_resource.deployer_setup]

  provisioner "local-exec" {
    command = "ansible-galaxy install -f juju4.adduser"
  }

  provisioner "local-exec" {
    command = "ansible -T 30 -u root -m apt -a 'name=sudo state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm"

    environment = {
      TF_STATE = "./"
    }
  }

  provisioner "local-exec" {
    command = "ansible-playbook -b -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --extra-vars 'username=${var.username}' --extra-vars 'user_pubkey=${format("%s/%s", data.external.workdir.result.workdir, var.public_keys)}' --extra-vars 'password_hash=${var.user_password_hash}' --inventory=${var.terraform_inventory_path} ${path.cwd}/ansible/playbooks/users.yml"

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

  count = var.swarm_nodes

  provisioner "local-exec" {
    command = "ansible -m lineinfile -b  -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} -a \"dest=/etc/hosts line='${cherryservers_server.swarm[count.index].primary_ip} ${cherryservers_server.swarm[count.index].hostname}'\" all"

    environment = {
      TF_STATE = "./"
    }
  }

}

resource "null_resource" "ansible_configure_ssh" {
  depends_on = [null_resource.swarm_ansible_configure_ssh]

  provisioner "local-exec" {
    command = "ansible -m lineinfile -b  -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} -a \"dest=/etc/hosts line='${cherryservers_server.deployer.primary_ip} ${cherryservers_server.deployer.hostname}'\" all"

    environment = {
      TF_STATE = "./"
    }
  }

  provisioner "local-exec" {
    command = "ansible-playbook -b -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --extra-vars 'sshd_config=${path.cwd}/ansible/files/sshd_config' --extra-vars 'banner=${format("%s/ansible/files/banner", data.external.workdir.result.workdir)}' --inventory=${var.terraform_inventory_path} ${path.cwd}/ansible/playbooks/sshd.yml"

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
    command = "ansible-galaxy install -f manala.cron"
  }

  provisioner "local-exec" {
    command = "ansible-playbook -b -u ${var.username} --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${path.cwd}/ansible/playbooks/cron.yml"

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
    command = "ansible-galaxy install -f geerlingguy.swap"
  }

  provisioner "local-exec" {
    command = "ansible-playbook -b -u ${var.username} --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${path.cwd}/ansible/playbooks/disable-swap.yml"

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
    command = "ansible-playbook -b -u ${var.username} --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} --extra-vars 'username=${var.username}' ./ansible/playbooks/swarm_nginx.yml"

    environment = {
      TF_STATE = "./"
    }
  }
}

data "template_file" "ssh_tunnel_service" {
  template = "${file("${path.cwd}/ansible/files/secure-tunnel-swarm.service.tpl")}"

  depends_on = [cherryservers_server.swarm]

  vars = {
    username = "${var.username}"
    target   = "${cherryservers_server.swarm.0.primary_ip}"
  }
}

resource "null_resource" "deployer_tunnel_setup" {
  depends_on = [data.template_file.ssh_tunnel_service, null_resource.ansible_swarm_disable_swap]

  provisioner "local-exec" {
    command = "rm -f id_ed25519_deployer_tunnel && rm -f id_ed25519_deployer_tunnel.pub && ssh-keygen -t ed25519 -f id_ed25519_deployer_tunnel -C 'dokku@stremio-addon-deployer' -q -N ''"
  }

  provisioner "local-exec" {
    command = format("cat <<\"EOF\" > \"%s\"\n%s\nEOF", "secure-tunnel-swarm.service", data.template_file.ssh_tunnel_service.rendered)
  }

  provisioner "local-exec" {
    command = "ansible -T 30 -b -u ${var.username} -m copy -a 'src=id_ed25519_deployer_tunnel.pub dest=/home/${var.username}/.ssh/ mode=0600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm_0"

    environment = {
      TF_STATE = "./"
    }
  }

#TODO
#Check this resource and specially this next provisioner as it looks like it is not required.
  provisioner "local-exec" {
    command = "ansible -T 30 -b -u ${var.username} -m shell -a 'echo -n command=\"beamup-sync-and-deploy\",restrict,permitopen=\"localhost:5000\" && cat /home/${var.username}/.ssh/id_ed25519_deployer_tunnel.pub >> /home/${var.username}/.ssh/authorized_keys' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm_0"

    environment = {
      TF_STATE = "./"
    }
  }

  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -b -u ${var.username} --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} --extra-vars 'username=${var.username}' ./ansible/playbooks/deployer_tunnel.yml"

    environment = {
      TF_STATE = "./"
    }
  }
}

data "template_file" "beamup_sync_swarm" {
  template = "${file("${path.cwd}/ansible/files/beamup-sync-swarm.sh.tpl")}"

  depends_on = [cherryservers_server.swarm]

  vars = {
    cloudflare_token   = "${trimspace(file("./creds/cloudflare_token"))}"
    cloudflare_zone_id = "${trimspace(file("./creds/cloudflare_zone_id"))}"
    cf_origin_ips      = "${cherryservers_server.swarm.0.primary_ip}"
  }
}

resource "null_resource" "swarm_deployer_script" {
  depends_on = [null_resource.deployer_tunnel_setup, data.template_file.beamup_sync_swarm]

  provisioner "local-exec" {
    command = format("cat <<\"EOF\" > \"%s\"\n%s\nEOF", "beamup-sync-swarm.sh", data.template_file.beamup_sync_swarm.rendered)
  }

  provisioner "local-exec" {
    command = "ansible -T 30 -b -u ${var.username} -m copy -a 'src=id_ed25519_deployer_sync.pub dest=/home/${var.username}/.ssh/ mode=0600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm_0"

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
    command = format("ansible -T 30 -u ${var.username} -m shell -a 'echo \"command=\\\"beamup-swarm-entry \\$SSH_ORIGINAL_COMMAND\\\",restrict %s\" >> /home/${var.username}/.ssh/authorized_keys' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} swarm", file("./id_ed25519_deployer_sync.pub"))

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

resource "null_resource" "hosts_firewall" {
  depends_on = [null_resource.deployer_tunnel_setup, null_resource.swarm_deployer_script]

  provisioner "local-exec" {
    command = "ansible -T 30 -b -u ${var.username} -m apt -a 'name=iptables-persistent state=present update_cache=yes' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} all"

    environment = {
      TF_STATE = "./"
    }
  }

  provisioner "local-exec" {
    command = "ansible-playbook -T 30 -b -u ${var.username} --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory=${var.terraform_inventory_path} ${path.cwd}/ansible/playbooks/iptables.yml"

    environment = {
      TF_STATE = "./"
    }
  }
}
