provider "cherryservers" {
  auth_token = "${trimspace(file("./creds/cherryservers"))}"
}
variable "region" {
  default = "EU-East-1"
}
variable "image" {
  default = "Debian 10 64bit"
}
variable "plan_id" {
  #default = "ssd_smart16"
  default = "94"
}

# The controller/deployer server
resource "cherryservers_server" "main-server" {
  project_id = "101781"
  region = "${var.region}"
  hostname = "stremio-addon-deployer"
  image = "${var.image}"
  plan_id = "${var.plan_id}"
  #ssh_keys_ids = [
  #  "${cherryservers_ssh.tf_deploy_key.id}"]
}
