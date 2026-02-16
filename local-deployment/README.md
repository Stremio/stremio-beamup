


## Introduction

This document provides instructions for setting up and deploying the Stremio Beamup project in a local environment. 

It is recommended to run this setup inside an Ubuntu virtual machine with sufficient disk space, CPU, and RAM. This approach allows deployment from any system using any VM software. Please follow the official instructions for your operating system and VM software to create and configure the virtual machine. 

Known working envirement (it may work with less resources):
- VM OS: ubuntu-24.04.3-live-server-amd64.iso
- VM disk: 50 gb
- VM CPUs: 8
- VM RAM: 16 gb

Note that these instructions are focused on deploying the core Stremio Beamup infrastructure itself, not on deploying individual addons to the platform.

Nested virtualization is also required for the local deployment.
To enable nested virtualization in Windows check:
https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/enable-nested-virtualization#enable-nested-virtualization

## prerequisites 

- install dependencies
```bash
./local-deployment/server-init.sh
```
This script only installs dependencies and base host setup.
A relogin to the terminal for the user is being used is required after previous step, also, user that runs this script must have sudo privileges witn no password.

- download base debian image
```bash
wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
```


## Deployment

**WARNING:** this only refers to deploying stremio-beamup itself, not deploying addons to it

1. Run `ssh-keygen -t ed25519 -f id_deploy` or `ssh-keygen -t ed25519 -f id_deploy -C "tf_deploy_key"`.
2. - `mkdir creds`.
   - `touch creds/cherryservers`.
   - `touch creds/cherryservers_project_id`.
3. Start an ssh-agent e.g. ``eval `ssh-agent` `` & load the key from step 1 into the agent - `ssh-add id_deploy`.
4. Create an ['authorized_keys'](https://www.ssh.com/ssh/authorized_keys/) containing the public keys of users who should access the deployment, including the public SSH Key generated in previous step.
5. Run `touch id_ed25519_deployer_sync.pub` to workaround a TF0.12 issue.
6. Setup CloudFlare
    1. `touch creds/cloudflare_zone_id`.
    2. `touch creds/cloudflare_token`.

7. Setup Terraform and apply configurations:
    - cd into the terraform/local directory:
      ```bash
      cd terraform/local
      ```
    - Run the Terraform initialization command:
      ```bash
      terraform init
      ```
    - Apply the Terraform configuration using the appropriate `.tfvars` file for your environment:
      ```bash
      terraform apply -var-file=dev.tfvars
      ```
    Make sure to copy and edit the `.tfvars` files from `dev.tfvars.example` if you haven't done so. Fill in the necessary information for your specific environment.  

8. Configure local wildcard DNS and port forwarding after the swarm VMs are up:
   ```bash
   ./local-deployment/dns-init.sh
   ```
   Optional environment overrides:
   - `LOCAL_BEAMUP_DOMAIN` (default: `beamup.test`)
   - `DNS_UPSTREAM` (default: `1.1.1.1`)
   - `SWARM_VM_NAME` (default: `stremio-beamup-swarm-0`)
   - `DEPLOYER_VM_NAME` (default: `stremio-addon-deployer`)
   - `A_RECORD_IP` (default: main VM LAN IP with last octet +/-1)
   - `HOST_LAN_IP` (auto-detected from default route)
   - `TARGET_IP` (auto-detected from `virsh domifaddr`)
   - `DEPLOYER_IP` (auto-detected from `virsh domifaddr`)


## Deploying addons 

After the local infrastructure is deployed, use this flow to deploy addons with `beamup-cli`:

1. Set your client DNS server to the IP address of the main VM.
2. Run `beamup config` and set the host to `a.beamup.test`.
3. Run `beamup deploy`.

Once these are done, addon deployment should work end-to-end in the local setup.
