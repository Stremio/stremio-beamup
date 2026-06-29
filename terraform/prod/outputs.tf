output "deployer_server_ip_addresses" {
  value = cherryservers_server.deployer.ip_addresses
}

output "swarm_servers_ip_addresses" {
  value = { for server in cherryservers_server.swarm : server.hostname => server.ip_addresses }
}
