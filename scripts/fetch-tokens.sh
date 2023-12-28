#!/usr/bin/env bash

# Processing JSON in shell scripts
# https://www.terraform.io/docs/providers/external/data_source.html#processing-json-in-shell-scripts

# Exit if any of the intermediate steps fail
set -e
set -x

# Extract "host" argument from the input into HOST shell variable
eval "$(jq -r '@sh "HOST=\(.host) SSH_KEY=\(.private_key)"')"

# Determine which user to use (pseudo-code)
if ssh -i $SSH_KEY beamup@$HOST "echo success" >/dev/null 2>&1; then
    SSH_USER=beamup
else
    SSH_USER=root
fi

# Fetch the manager join token
MANAGER=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i $SSH_KEY $SSH_USER@$HOST docker swarm join-token manager -q)

# Fetch the worker join token
WORKER=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i $SSH_KEY $SSH_USER@$HOST docker swarm join-token worker -q)

# Produce a JSON object containing the tokens
jq -n --arg manager "$MANAGER" --arg worker "$WORKER" \
    '{"manager":$manager,"worker":$worker}'

