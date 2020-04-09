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
  name   = "tf_deploy_key"
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

  connection {
    host = "${self.primary_ip}"
    private_key = "${file(var.private_key)}"
    timeout = "30m"
  }

  provisioner "file" {
    source = "scripts"
    destination = "/usr/local/bin"
  }

  provisioner "remote-exec" {
    script = "/usr/local/bin/beamup-setup"
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

  connection {
    host = "${self.primary_ip}"
    private_key = "${file(var.private_key)}"
    timeout = "30m"
  }
  provisioner "remote-exec" {
    inline = [
		"export CHANNEL=stable",
		"wget -nv -O - https://get.docker.com/ | sh",
		"apt install -y vim nodejs nginx",
		"echo -e 'net.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.default.disable_ipv6=1\nnet.ipv6.conf.lo.disable_ipv6=1\nvm.swappiness=0\nvm.overcommit_memory=1' >>/etc/sysctl.conf",
		"sysctl -p",
	]
  }
}
