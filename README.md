# stremio-beamup
🛠️ A platform as a service (PaaS) hosting for Stremio addons: as easy a Heroku/Now.sh, but DYI and without the restrictions.

It is based on [Dokku](https://github.com/dokku/dokku), but with two significant differences:
* It's designed with public use in mind - you can authenticate yourself using your GitHub account and push addons
* It only supports Stremio addons and it's optimized for them (by using specific caching policies)


To deploy this yourself, you'll need:

* A [Cherryservers account](https://portal.cherryservers.com/#/register) and API key
* [Terraform](https://www.terraform.io/downloads.html) - tested with version 1.6.2
* [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html) - tested with ansible community package 7.2
* Go & [Terraform inventory](https://github.com/adammck/terraform-inventory)
* A domain name from any domain provider.
* A [CloudFlare account](https://www.cloudflare.com/) and API key

## Deployment

**WARNING:** this only refers to deploying stremio-beamup itself, not deploying addons to it


1. Run `ssh-keygen -t ed25519 -f id_deploy`.
2. Register on [Cherryservers](https://cherryservers.com), fund your account and create a project.
3. Create an API key and paste it into a new file: `creds/cherryservers`; paste your numeric project ID into `creds/cherryservers-project-id`.
4. Start an ssh-agent e.g. ``eval `ssh-agent` `` & load the key from step 1 into the agent - `ssh-add id_deploy`.
5. Create an ['authorized_keys'](https://www.ssh.com/ssh/authorized_keys/) containing the public keys of users who should access the deployment.
6. Run `touch id_ed25519_deployer_sync.pub` to workaround a TF0.12 issue.
7. Register a domain for the service (it can be done in CloudFlare too, in the next step).
8. Create an account on [CloudFlare](https://www.cloudflare.com); follow the steps to add a site/zone (to add the domain) and add the Zone ID in `creds/cloudflare_zone_id`; create an API Token with DNS:Edit permission for the zone created and add it to `creds/cloudflare_token`.
9. Create a DNS A Record for the deployer public IP, e.g.: deployer.thebestbeamup.com.
This DNS can be used with `beamup-cli` to deploy the addons. It can be created in CloudFlare.
10. Run `terraform apply`.

By default, this will bootstrap a single server called `deployer` that can be used to deploy addons too and a docker swarm with two nodes where the addons will be deployed.

**CAVEAT:** Depending on the Cherryservers node setup, the first ansible playbook execution might fail with `"E: Could not get lock /var/lib/dpkg/lock - open (11: Resource temporarily unavailable"` error. This is due to server setup scripts on the Cherryservers, simply restart the `terraform apply` command.

## Deploying an addon

Use [beamup-cli](https://github.com/Stremio/stremio-beamup-cli) to deploy addons.

### Setting environment variables
Setting/getting environment variables is similar to the way Dokku does it, however you do it through ssh, and you need to pass the same addon slug that's used in the git remote that `./cli/beamup` adds.

For example: `ssh dokku@deployer.beamup.dev config:set 768c7b2546f2/hello NODE_ENV=production`

### Addon application logs
Logs of deployed addons can easily be fetched in way, similar to the way Dokku does it, however through ssh

For example: `ssh dokku@deployer.beamup.dev logs 768c7b2546f2/hello`

## Architecture decisions

* Why Dokku: it supports both Heroku buildpacks and Docker images, and it's super easy to configure and use
* Why we're using container ports rather than container IPs: so we can make use of the swarm routing for zero downtime

## FAQ

### Why Cherryservers?
Because they have a Terraform provider and you can pay with Bitcoin.

### Can I use this as a general purpose PaaS?
No - it performs addon-specific checks/optimizations. You can easily modify it for general-purpose usage though, by tweaking NGINX configs and Dokku CHECKS.

### Does it only support nodejs?
No, it supports every stack that there's a heroku buildpack for, as well as any repo that has a `Dockerfile`.
