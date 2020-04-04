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
    host = "${cherryservers_server.deployer.primary_ip}"
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
