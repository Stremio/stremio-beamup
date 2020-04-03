# stremio-beamup
🛠️ A platform as a service (PaaS) hosting for Stremio addons: as easy a Heroku/Now.sh, but DYI and without the restrictions.

It is based on [Dokku](https://github.com/dokku/dokku), but with two significant differences:
* It's designed with public use in mind - you can authenticate yourself using your GitHub account and push apps
* It only supports Stremio addons and it's optimized for them (by using specific caching policies)


To deploy this yourself, you'll need:

* A Cherryservers account and API key
* Terraform

## Deployment

**WARNING:** this only refers to deploying stremio-beamup itself, not deploying apps to it

1. Run `ssh-keygen -t ed25519 -f id_deploy`
2. Register on [Cherryservers](cherryservers.com) and fund your account
3. Create an API key and paste it into a new file: `creds/cherryservers`; paste your numeric project ID into `creds/cherryservers-project-id`
4. Run `terraform apply`

By default, this will bootstrap a single server called `deployer` that can be used to deploy addons too.

## FAQ

### Why Cherryservers?

### Can I use this as a general purpose PaaS?

### Does it only support nodejs?
No, it supports every stack that there's a heroku buildpack for, as well as any Docker container.
