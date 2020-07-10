#!/usr/bin/env bash

# Processing JSON in shell scripts
# https://www.terraform.io/docs/providers/external/data_source.html#processing-json-in-shell-scripts

# Exit if any of the intermediate steps fail
set -e


WORKDIR=`pwd`
jq -n --arg workdir "$WORKDIR" '{"workdir": $workdir}'
