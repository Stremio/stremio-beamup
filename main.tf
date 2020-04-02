provider "cherryservers" {
  auth_token = "${trimspace(file("./creds/cherryservers"))}"
}
variable "dokku_version" {
  default="0.20.0"
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
  project_id = "101781"
  region = "${var.region}"
  hostname = "stremio-addon-deployer"
  image = "${var.image}"
  plan_id = "${var.plan_id}"
  ssh_keys_ids = ["${cherryservers_ssh.tf_deploy_key.id}"]

  provisioner "remote-exec" {
    inline = [
      "wget https://raw.githubusercontent.com/dokku/dokku/v${var.dokku_version}/bootstrap.sh",
      "DOKKU_TAG=v${var.dokku_version} bash bootstrap.sh"
    ]

    connection {
      type = "ssh"
      user = "root"
      host = "${cherryservers_server.deployer.primary_ip}"
      private_key = "${file(var.private_key)}"
      timeout = "30m"
    }
  }
}
