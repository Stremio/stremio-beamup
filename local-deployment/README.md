


## prerequisites 

- install dependencies
```bash
./local-deployment/server-init.sh
```

- download base debian image
```bash
wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2
```


## Deployment

**WARNING:** this only refers to deploying stremio-beamup itself, not deploying addons to it

1. Run `ssh-keygen -t ed25519 -f id_deploy` or `ssh-keygen -t ed25519 -f id_deploy -C "tf_deploy_key"`.
2. - `touch creds/cherryservers`.
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
    Make sure to copy and edit the `.tfvars` files from `dev.tfvars.example` if you haven't done so. Fill in the necessary information for your specific environment (either `development`, `production` or other).  
8. Create a DNS A Record for the deployer's public IP, e.g.: `deployer.beamup.dev`.  
It can be created in CloudFlare. This DNS can be used with `beamup-cli` to deploy the addons.





`sudo nano /etc/libvirt/qemu.conf`
add `security_driver = "none" `
`sudo systemctl restart libvirtd`
