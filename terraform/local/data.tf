data "external" "swarm_tokens" {
  program = ["${var.project_dir}/scripts/fetch-tokens.sh"]

  query = {
    host        = local.swarm_manager_public_ip
    private_key = var.private_key
  }

  depends_on = [null_resource.swarm_os_setup]
}

data "external" "workdir" {
  program = ["${var.project_dir}/scripts/fetch-workdir.sh"]
}

data "template_file" "ssh_tunnel_service" {
  template = file("${var.project_dir}/ansible/files/secure-tunnel-swarm.service.tpl")

  depends_on = [libvirt_domain.swarm]

  vars = {
    username = var.username
    target   = local.swarm_manager_public_ip
  }
}

data "template_file" "beamup_sync_swarm" {
  template = file("${var.project_dir}/ansible/files/beamup-sync-swarm.sh.tpl")

  depends_on = [libvirt_domain.swarm]

  vars = {
    cloudflare_token   = trimspace(file("${var.project_dir}/creds/cloudflare_token"))
    cloudflare_zone_id = trimspace(file("${var.project_dir}/creds/cloudflare_zone_id"))
    cf_origin_ips      = local.swarm_manager_public_ip
  }
}

data "template_file" "user_data" {
  template = file("${path.cwd}/cloud_init.cfg")
  vars = {
    ssh_public_key = trimspace(file("${var.private_key}.pub"))
  }
}