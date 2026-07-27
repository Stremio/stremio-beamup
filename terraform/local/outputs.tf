output "deployer_server_ip_addresses" {
  description = "IP addresses of the deployer server"
  value       = local.deployer_public_ip
}

output "swarm_servers_ip_addresses" {
  description = "IP addresses of all swarm servers"
  value       = local.swarm_public_ips
}

output "deployer_hostname" {
  description = "Hostname of the deployer server"
  value       = local.deployer_hostname
}

output "swarm_hostnames" {
  description = "Hostnames of all swarm servers"
  value       = local.swarm_hostnames
}