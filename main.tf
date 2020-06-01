provider "cherryservers" {
    auth_token = "${trimspace(file("./creds/cherryservers"))}"
}

variable "private_key" {
    default = "./id_deploy"
}

variable "public_keys" {
    default = "./authorized_keys"
}

variable "region" {
    default = "EU-East-1"
}

variable "image" {
    default = "Debian 9 64bit"
}

variable "domain" {
    default = "beamup.dev"
}

variable "swarm_nodes" {
    default = "2"
}

# corresponds to ssd_smart16
variable "plan_id" {
    default = "94"
}

variable "username" {
	default = "beamup"
}

resource "cherryservers_ssh" "tf_deploy_key" {
    name   = "tf_deploy_key_testing"
    public_key = "${file("${var.private_key}.pub")}"
}

# The controller/deployer server
resource "cherryservers_server" "deployer" {
    project_id = "${trimspace(file("./creds/cherryservers-project-id"))}"
    region = "${var.region}"
    hostname = "stremio-addon-deployer"
    image = "${var.image}"
    plan_id = "${var.plan_id}"
    ssh_keys_ids = ["${cherryservers_ssh.tf_deploy_key.id}"]
    tags = {
        Name        = "deployer"
        Environment = "Stremio Beamup"
    }
}

resource "null_resource" "deployer_setup" {
    depends_on = [ "cherryservers_server.deployer" ]

#    provisioner "local-exec" {
#        command = "echo 'Waiting for package lock...' && sleep 90"
#    }

	provisioner "local-exec" {
		command = "ansible -m lineinfile -b  -u root --ssh-extra-args='-o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory -a \"dest=/etc/hosts line='127.0.1.1 stremio-addon-deployer'\" deployer"
	}

	#
	# Install packages
	#
	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=nodejs state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=vim-tiny state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	#
	# Run setup script
	#
	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m copy -a 'src=scripts/beamup-setup-deployer dest=/usr/local/bin/ mode=0700' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m shell -a 'DOMAIN=${var.domain} /usr/local/bin/beamup-setup-deployer' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}
}

# The swarm servers
# TODO: add deployer in authorized-keys
resource "cherryservers_server" "swarm" {
    count = "${var.swarm_nodes}"
    project_id = "${trimspace(file("./creds/cherryservers-project-id"))}"
    region = "${var.region}"
    hostname = "stremio-beamup-swarm-${count.index}"
    image = "${var.image}"
    # ssd_smart16 is 94
    # E3-1240v3 is 86
    # E3-1240V5 is 113
    # E5-1650V2 is 106
    plan_id = "86"
    ssh_keys_ids = ["${cherryservers_ssh.tf_deploy_key.id}"]
    tags = {
        Name        = "swarm"
        Environment = "Stremio Beamup"
    }

    # XXX: move to a separate resource
	# provisioner "local-exec" {
	#	command = "ansible -m lineinfile -b  -u root --ssh-extra-args='-o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory -a \"dest=/etc/hosts line='127.0.1.1 stremio-beamup-swarm-${count.index}'\" swarm-${count.index}"
	# }
}


resource "null_resource" "swarm_docker_create" {
    depends_on = [ "cherryservers_server.swarm" ]

	provisioner "local-exec" {
		command = "ansible-galaxy install -f geerlingguy.docker"
	}

	provisioner "local-exec" {
		command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory ${path.cwd}/ansible-files/docker.yml"
	}
}

resource "null_resource" "swarm_os_setup" {
    depends_on = [ "null_resource.swarm_docker_create" ]


#    provisioner "local-exec" {
#        command = "echo 'Waiting for package lock...' && sleep 90"
#    }

	#
	# Fine tune some sysctl values
	#
	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m sysctl -a 'name=net.ipv6.conf.all.disable_ipv6 value=1 state=present' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}
	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m sysctl -a 'name=net.ipv6.conf.default.disable_ipv6 value=1 state=present' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}
	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m sysctl -a 'name=vm.swappiness value=0 state=present' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}
	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m sysctl -a 'name=vm.overcommit_memory value=1 state=present reload=yes' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	#
	# Install packages
	#

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=nodejs state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=nginx state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=vim-tiny state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=python-pip state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m pip -a 'name=docker state=present' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	#
	# Init the swarm on the first server
	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m docker_swarm -a 'state=present' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm_0"
	}
}

data "external" "swarm_tokens" {
	program = ["${path.cwd}/scripts/fetch-tokens.sh"]

	query = {
		host = "${cherryservers_server.swarm.0.primary_ip}"
		private_key = "${var.private_key}"
	}

	depends_on = [ "null_resource.swarm_os_setup" ]
}

resource "null_resource" "swarm_docker_join" {
    depends_on = [ "null_resource.swarm_os_setup" , "data.external.swarm_tokens" ]
    count = "${var.swarm_nodes - 1}"

	connection {
		private_key = "${file(var.private_key)}"
		host = "${element(cherryservers_server.swarm.*.primary_ip, count.index + 1)}"
	}

	provisioner "remote-exec" {
		inline = [
			"${format("docker swarm join --token %s %s:2377", data.external.swarm_tokens.result.manager, cherryservers_server.swarm.0.primary_ip)}"
		]
	}
}

resource "null_resource" "swarm_docker_setup" {
    depends_on = [ "null_resource.swarm_docker_join" ]


	#
	# Copy beamup swarm setup script & execute
	#
	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m copy -a 'src=swarm-syncer/beamup-sync-and-deploy dest=/usr/local/bin/ mode=0700' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m copy -a 'src=swarm-syncer/beamup-sync-swarm dest=/usr/local/bin/ mode=0700' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m shell -a '/usr/local/bin/beamup-sync-and-deploy' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}
}

resource "null_resource" "ansible_beamup_users" {
    depends_on = [ "null_resource.swarm_docker_setup", "null_resource.deployer_setup"  ]

	provisioner "local-exec" {
		command = "ansible-galaxy install -f juju4.adduser"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=sudo state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	provisioner "local-exec" {
		command = "ansible-playbook -b -u root --ssh-extra-args='-o StrictHostKeyChecking=no' --extra-vars 'username=${var.username}' --extra-vars 'user_pubkey=${format("%s/%s", path.module, var.public_keys)}' --inventory-file=$GOPATH/bin/terraform-inventory ${path.cwd}/ansible-files/users.yml"
	}

	# Configure a user for the monitoring
	provisioner "local-exec" {
		command = "ansible-playbook -b -u root --ssh-extra-args='-o StrictHostKeyChecking=no' --extra-vars 'username=icinga' --extra-vars 'user_pubkey=${format("%s/%s", path.module, var.public_keys)}' --inventory-file=$GOPATH/bin/terraform-inventory ${path.cwd}/ansible-files/users.yml"
	}

	# XXX: ensire sudo does not ask for password
	provisioner "local-exec" {
		command = "ansible -m lineinfile -b  -u root --ssh-extra-args='-o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory -a \"dest=/etc/sudoers regexp='^(.*)%sudo(.*)' line='%sudo ALL=(ALL:ALL) NOPASSWD:ALL'\" all"
	}
}

resource "null_resource" "ansible_configure_ssh" {
	depends_on = [
		"null_resource.ansible_beamup_users",
	]

	provisioner "local-exec" {
		command = "ansible-playbook -b -u root --ssh-extra-args='-o StrictHostKeyChecking=no' --extra-vars 'sshd_config=${path.cwd}/ansible-files/sshd_config' --extra-vars 'banner=${path.module}/ansible-files/banner' --inventory-file=$GOPATH/bin/terraform-inventory ${path.cwd}/ansible-files/sshd.yml"
	}
}
