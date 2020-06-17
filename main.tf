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

	provisioner "local-exec" {
		command = "echo 'Waiting for setup scripts to finish...' && sleep 60"
	}

	provisioner "local-exec" {
		command = "ansible -m lineinfile -b  -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory -a \"dest=/etc/hosts line='127.0.1.1 stremio-addon-deployer'\" deployer"
	}

	#
	# Install packages
	#
	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=curl state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}

	provisioner "local-exec" {
		command = "ansible -m shell -b  -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory -a 'curl -sL https://deb.nodesource.com/setup_12.x | bash - ' deployer"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=nodejs state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=vim state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
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

	#
	# Enable the beamup dokku plugin
	#
	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m copy -a 'src=dokku-plugins/beamup-trigger-swarm-sync dest=/var/lib/dokku/plugins/available mode=0755' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m file -a 'src=/var/lib/dokku/plugins/available/beamup-trigger-swarm-sync dest=/var/lib/dokku/plugins/enabled/beamup-trigger-swarm-sync state=link' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}

	#
	# Install the beamup scripts
	#
	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m copy -a 'src=scripts/beamup-entry dest=/usr/local/bin/ mode=0755' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}
	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m copy -a 'src=scripts/beamup-sync-keys dest=/usr/local/bin/ mode=0755' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
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
}


resource "null_resource" "swarm_docker_create" {
    depends_on = [ "cherryservers_server.swarm" ]

	provisioner "local-exec" {
		command = "echo 'Waiting for setup scripts to finish...' && sleep 60"
	}

	provisioner "local-exec" {
		command = "ansible-galaxy install -f geerlingguy.docker"
	}

	provisioner "local-exec" {
		command = "ansible-playbook -T 30 -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory ${path.cwd}/ansible/playbooks/docker.yml"
	}
}

resource "null_resource" "swarm_hosts" {
    count = "${var.swarm_nodes}"

    depends_on = [ "cherryservers_server.swarm" ]

    provisioner "local-exec" {
        command = "ansible -m lineinfile -b  -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory -a \"dest=/etc/hosts line='127.0.1.1 stremio-beamup-swarm-${count.index}'\" swarm_${count.index}"
    }
}

resource "null_resource" "swarm_os_setup" {
    depends_on = [ "null_resource.swarm_docker_create" ]

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
		command = "ansible -T 30 -u root -m apt -a 'name=curl state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	provisioner "local-exec" {
		command = "ansible -m shell -b  -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory -a 'curl -sL https://deb.nodesource.com/setup_12.x | bash - ' swarm"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=nodejs state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=nginx state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=vim state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
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
    depends_on = [ "null_resource.swarm_docker_join", "null_resource.swarm_hosts" ]


	#
	# Copy beamup swarm setup script & execute
	#
	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m copy -a 'src=swarm-syncer/beamup-sync-and-deploy dest=/usr/local/bin/ mode=0755' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m copy -a 'src=swarm-syncer/beamup-sync-swarm dest=/usr/local/bin/ mode=0755' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m shell -a '/usr/local/bin/beamup-sync-and-deploy' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}
}

resource "null_resource" "ansible_beamup_users" {
    depends_on = [ "null_resource.swarm_docker_setup", "null_resource.deployer_setup" ]

	provisioner "local-exec" {
		command = "ansible-galaxy install -f juju4.adduser"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u root -m apt -a 'name=sudo state=present update_cache=yes cache_valid_time=3600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}

	provisioner "local-exec" {
		command = "ansible-playbook -b -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --extra-vars 'username=${var.username}' --extra-vars 'user_pubkey=${format("%s/%s", path.module, var.public_keys)}' --inventory-file=$GOPATH/bin/terraform-inventory ${path.cwd}/ansible/playbooks/users.yml"
	}

	# Configure a user for the monitoring
	provisioner "local-exec" {
		command = "ansible-playbook -b -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --extra-vars 'username=icinga' --extra-vars 'user_pubkey=${format("%s/%s", path.module, var.public_keys)}' --inventory-file=$GOPATH/bin/terraform-inventory ${path.cwd}/ansible/playbooks/users.yml"
	}

	# XXX: ensire sudo does not ask for password
	provisioner "local-exec" {
		command = "ansible -m lineinfile -b  -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory -a \"dest=/etc/sudoers regexp='^(.*)%sudo(.*)' line='%sudo ALL=(ALL:ALL) NOPASSWD:ALL'\" all"
	}
}


#
# After creating this resource, root access via SSH is forbidden; login as user 'beamup' instead
#
resource "null_resource" "ansible_configure_ssh" {
	depends_on = [
		"null_resource.ansible_beamup_users",
	]

	provisioner "local-exec" {
		command = "ansible -m lineinfile -b  -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory -a \"dest=/etc/hosts line='${cherryservers_server.swarm.0.primary_ip} ${cherryservers_server.swarm.0.hostname}'\" all"
	}

	provisioner "local-exec" {
		command = "ansible -m lineinfile -b  -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory -a \"dest=/etc/hosts line='${cherryservers_server.swarm.1.primary_ip} ${cherryservers_server.swarm.1.hostname}'\" all"
	}

	provisioner "local-exec" {
		command = "ansible -m lineinfile -b  -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory -a \"dest=/etc/hosts line='${cherryservers_server.deployer.primary_ip} ${cherryservers_server.deployer.hostname}'\" all"
	}

	provisioner "local-exec" {
		command = "ansible-playbook -b -u root --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --extra-vars 'sshd_config=${path.cwd}/ansible/files/sshd_config' --extra-vars 'banner=${path.module}/ansible/files/banner' --inventory-file=$GOPATH/bin/terraform-inventory ${path.cwd}/ansible/playbooks/sshd.yml"
	}
}

resource "null_resource" "ansible_configure_cron" {
	depends_on = [
		"null_resource.ansible_configure_ssh",
	]

	provisioner "local-exec" {
		command = "ansible-galaxy install -f manala.cron"
	}

	provisioner "local-exec" {
		command = "ansible-playbook -b -u ${var.username} --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory ${path.cwd}/ansible/playbooks/cron.yml"
	}
}

resource "null_resource" "ansible_swarn_disable_swap" {
	depends_on = [
		"null_resource.ansible_configure_ssh",
	]

	provisioner "local-exec" {
		command = "ansible-galaxy install -f geerlingguy.swap"
	}

	provisioner "local-exec" {
		command = "ansible-playbook -b -u ${var.username} --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory ${path.cwd}/ansible/playbooks/disable-swap.yml"
	}
}

data "template_file" "ssh_tunnel_service" {
	template = "${file("${path.cwd}/ansible/files/secure-tunnel-swarm.service.tpl")}"

	depends_on = [ "cherryservers_server.swarm" ]

	vars {
		username = "${var.username}"
		target = "${cherryservers_server.swarm.1.primary_ip}"
	}
}

resource "null_resource" "deployer_tunnel_setup" {
	depends_on = [ "data.template_file.ssh_tunnel_service", "null_resource.ansible_swarn_disable_swap" ]

	provisioner "local-exec" {
		command = "rm -f id_ed25519_deployer && rm -f id_ed25519_deployer.pub && ssh-keygen -t ed25519 -f id_ed25519_deployer -C 'dokku@stremio-addon-deployer' -q -N ''"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -b -u ${var.username} -m copy -a 'src=id_ed25519_deployer dest=/home/dokku/.ssh/id_ed25519 mode=0600 owner=dokku group=dokku' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -b -u ${var.username} -m copy -a 'src=id_ed25519_deployer dest=/home/${var.username}/.ssh/id_ed25519 mode=0600 owner=${var.username} group=${var.username}' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -b -u ${var.username} -m copy -a 'src=id_ed25519_deployer.pub dest=/home/${var.username}/.ssh/ mode=0600' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm_1"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -b -u ${var.username} -m shell -a 'echo -n command=\"beamup-sync-and-deploy\",restrict,permitopen=\"localhost:5000\" && cat /home/${var.username}/.ssh/id_ed25519_deployer.pub >> /home/${var.username}/.ssh/authorized_keys' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm_1"
	}

	provisioner "local-exec" {
		command = "${format("cat <<\"EOF\" > \"%s\"\n%s\nEOF", "secure-tunnel-swarm.service", data.template_file.ssh_tunnel_service.rendered)}"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -b -u ${var.username} -m copy -a 'src=secure-tunnel-swarm.service dest=/etc/systemd/system/secure-tunnel.service' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -b -u ${var.username} -m shell -a 'ssh-keyscan -T 10 ${cherryservers_server.swarm.0.primary_ip} >> /root/.ssh/known_hosts ' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -b -u ${var.username} -m shell -a 'ssh-keyscan -T 10 ${cherryservers_server.swarm.1.primary_ip} >> /root/.ssh/known_hosts ' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u ${var.username} -m shell -a 'ssh-keyscan -T 10 ${cherryservers_server.swarm.0.primary_ip} >> /home/${var.username}/.ssh/known_hosts ' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u ${var.username} -m shell -a 'ssh-keyscan -T 10 ${cherryservers_server.swarm.1.primary_ip} >> /home/${var.username}/.ssh/known_hosts ' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -b -u ${var.username} -m shell -a 'ssh-keyscan -T 10 ${cherryservers_server.swarm.0.hostname} >> /home/dokku/.ssh/known_hosts ' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -b -u ${var.username} -m shell -a 'ssh-keyscan -T 10 ${cherryservers_server.swarm.1.hostname} >> /home/dokku/.ssh/known_hosts ' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -b -u ${var.username} -m systemd -a 'name=secure-tunnel.service enabled=yes masked=no state=started' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory deployer"
	}
}

data "template_file" "beamup_sync_swarm" {
	template = "${file("${path.cwd}/ansible/files/beamup-sync-swarm.sh.tpl")}"

	depends_on = [ "cherryservers_server.swarm" ]

	vars {
		cloudflare_token = "${trimspace(file("./creds/cloudflare_token"))}"
		cloudflare_zone_id = "${trimspace(file("./creds/cloudflare_zone_id"))}"
		cf_origin_ips = "${cherryservers_server.swarm.0.primary_ip}"
	}
}

resource "null_resource" "swarm_deployer_script" {
    depends_on = [ "null_resource.deployer_tunnel_setup", "data.template_file.beamup_sync_swarm" ]

	provisioner "local-exec" {
		command = "${format("cat <<\"EOF\" > \"%s\"\n%s\nEOF", "beamup-sync-swarm.sh", data.template_file.beamup_sync_swarm.rendered)}"
	}

	provisioner "local-exec" {
		command = "ansible -T 30 -u ${var.username} -m copy -a 'src=beamup-sync-swarm.sh dest=/home/beamup/beamup-sync-swarm.sh mode=0755' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm_0"
	}

	provisioner "local-exec" {
		command = "${format("ansible -T 30 -u ${var.username} -m shell -a 'echo \"command=\\\"/home/beamup/beamup-sync-swarm.sh\\\",restrict %s\" >> /home/beamup/.ssh/authorized_keys' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory swarm", file("./id_ed25519_deployer.pub"))}"
	}

	provisioner "local-exec" {
		command = "ansible -m lineinfile -b  -u root --ssh-extra-args='-o StrictHostKeyChecking=no' -a \"dest=/etc/sudoers regexp='^(.*)beamup(.*)' line='beamup ALL=(ALL) NOPASSWD: /bin/systemctl restart nginx'\" --inventory-file=$GOPATH/bin/terraform-inventory swarm"
	}


}

resource "null_resource" "hosts_firewall" {
	depends_on = [ "null_resource.deployer_tunnel_setup", "null_resource.swarm_deployer_script" ]

	provisioner "local-exec" {
		command = "ansible -T 30 -b -u ${var.username} -m apt -a 'name=iptables-persistent state=present update_cache=yes' --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory all"
	}

	provisioner "local-exec" {
		command = "ansible-playbook -T 30 -b -u ${var.username} --ssh-extra-args='-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no' --inventory-file=$GOPATH/bin/terraform-inventory ${path.cwd}/ansible/playbooks/iptables.yml"
	}
}
