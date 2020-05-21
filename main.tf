provider "cherryservers" {
    auth_token = "${trimspace(file("./creds/cherryservers"))}"
}

variable "private_key" {
    default = "./id_deploy"
}

variable "region" {
    default = "EU-East-1"
}

variable "image" {
    default = "Ubuntu 18.04 64bit"
}

# corresponds to ssd_smart16
variable "plan_id" {
    default = "94"
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

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m copy -a 'src=scripts/beamup-setup-deployer dest=/usr/local/bin/ mode=0700' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m shell -a '/usr/local/bin/beamup-setup-deployer' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}
}

# The swarm servers
# TODO: add deployer in authorized-keys
resource "cherryservers_server" "swarm" {
    count = 2
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
}


resource "null_resource" "swarm_docker_setup" {
    depends_on = [ "cherryservers_server.swarm" ]

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m shell -a 'CHANNEL=stable wget -nv -O - https://get.docker.com/ | sh ' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}
}

resource "null_resource" "swarm_setup" {
    depends_on = [ "null_resource.swarm_docker_setup" ]


	#
	# Install packages
	#

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=nodejs state=present update_cache=yes' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=nginx state=present update_cache=yes' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=vim-tiny state=present update_cache=yes' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

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
	# Copy beamup swarm setup script & execute
	#
	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m copy -a 'src=swarm-syncer/beamup-sync-and-deploy dest=/usr/local/bin/ mode=0700' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}
	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m shell -a '/usr/local/bin/beamup-sync-and-deploy' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}
}
