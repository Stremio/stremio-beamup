data "external" "swarm_tokens" {
  program = ["${var.project_dir}/scripts/fetch-tokens.sh"]

  query = {
    host        = "${cherryservers_server.swarm.0.ip_addresses[0].address}"
    private_key = "${var.private_key}"
  }

  depends_on = [null_resource.swarm_os_setup]

}

data "external" "workdir" {
  program = ["${var.project_dir}/scripts/fetch-workdir.sh"]
}

data "template_file" "ssh_tunnel_service" {
  template = file("${var.project_dir}/ansible/files/secure-tunnel-swarm.service.tpl")

  depends_on = [cherryservers_server.swarm]

  vars = {
    username = "${var.username}"
    target   = "${cherryservers_server.swarm.0.ip_addresses[0].address}"
  }
}

data "template_file" "beamup_sync_swarm" {
  template = file("${var.project_dir}/ansible/files/beamup-sync-swarm.sh.tpl")

  depends_on = [cherryservers_server.swarm]

  vars = {
    cloudflare_token   = "${trimspace(file("${var.project_dir}/creds/cloudflare_token"))}"
    cloudflare_zone_id = "${trimspace(file("${var.project_dir}/creds/cloudflare_zone_id"))}"
    cf_origin_ips      = "${cherryservers_server.swarm.0.ip_addresses[0].address}"
  }
}
