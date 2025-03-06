#!/usr/bin/env bash
# set -x
cd /home/beamup/
echo "Let's wait 5 seconds for registry to update new addons"
sleep 5
CF_TOKEN=${cloudflare_token} CF_ORIGIN_IPS=${cf_origin_ips} CF_ZONE_ID=${cloudflare_zone_id} beamup-sync-swarm $HOME/apps.yaml $HOME/apps.conf && docker stack deploy --prune --compose-file $HOME/apps.yaml beamup && sudo systemctl restart nginx
