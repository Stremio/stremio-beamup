# stremio-beamup
🛠️ A platform as a service (PaaS) hosting for Stremio addons: as easy a Heroku/Now.sh, but DYI and without the restrictions.

It is based on [Dokku](https://github.com/dokku/dokku), but with two significant differences:
* It's designed with public use in mind - you can authenticate yourself using your GitHub account and push addons
* It only supports Stremio addons and it's optimized for them (by using specific caching policies)


To deploy this yourself, you'll need:

* A [Cherryservers account](https://portal.cherryservers.com/#/register) and API key
* [Terraform](https://www.terraform.io/downloads.html) - version 0.12 or later
* [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html)
* Go & [Terraform inventory](https://github.com/adammck/terraform-inventory)

## Deployment

**WARNING:** this only refers to deploying stremio-beamup itself, not deploying addons to it


1. Run `ssh-keygen -t ed25519 -f id_deploy`
2. Register on [Cherryservers](cherryservers.com) and fund your account
3. Create an API key and paste it into a new file: `creds/cherryservers`; paste your numeric project ID into `creds/cherryservers-project-id`
4. Start an ssh-agent & load the key from step 1 into the agent - `ssh-add id_deploy`
5. Run `terraform apply`

By default, this will bootstrap a single server called `deployer` that can be used to deploy addons too and a docker swarm with two nodes where the addons will be deployed.


## Deploying an addon

To deploy an addon, you first need to have your SSH key added to your GitHub account; then, `cd` into the directory of your addon, and do `./cli/beamup <beamup deployer hostname> add-remote <github username> <addon name>`; then, `git push beamup master`

Prerequisites and good to know:
* Works on UNIX-like operating systems (Linux, macOS) but it should also work on Windows in Git Bash or the Linux subsystem
* You can use `git push beamup master` to update your addons as well
* Also, when you run `git push beamup master`, you'll see the deployment log and the URL at which you can access your addon
* Your addon repo must suppport one of the Heroku buildpacks or must have a `Dockerfile`; with Nodejs, simply having a `package.json` in the repo should be sufficient
* It's based on Dokku, so whatever you can deploy there you can also deploy on Beamup (it's using the same build system); however, some features are not supported such as custom NGINX config

### Setting environment variables
Setting/getting environment variables is similar to the way Dokku does it, however you do it through ssh, and you need to pass the same addon slug that's used in the git remote that `./cli/beamup` adds.

For example: `ssh dokku@deployer.beamup.dev config:set 768c7b2546f2/hello NODE_ENV=production`

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
