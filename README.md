# stremio-addon-paas
🛠️ A platform as a service (PaaS) hosting for Stremio addons: as easy a Heroku/Now.sh, but DYI and without the restrictions.

To deploy this yourself, you'll need:

* A Cherryservers account and API key
* Terraform

## Deployment

**WARNING:** this only refers to deploying stremio-addon-paas itself, not deploying apps to it

1. Run `ssh-keygen -t ed25519 -f id_deploy`
2. Register on [Cherryservers](cherryservers.com) and fund your account
3. Create an API key and paste it into a new file: `creds/cherryservers`

## FAQ


