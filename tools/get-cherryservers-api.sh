#!/bin/bash
#https://api.cherryservers.com/doc/

# Check if an endpoint URL was provided as an argument
if [ $# -ne 1 ]; then
  echo "Usage: $0 <API_ENDPOINT>"
  echo "Example:"
  echo "./tools/test-cherryservers-api.sh https://api.cherryservers.com/v1/teams"
  exit 1
fi

# Read the API key from the file
API_KEY=$(cat creds/cherryservers)

# Extract the endpoint URL from the argument
API_ENDPOINT="$1"

# Make a GET request to the API endpoint with curl
curl -s -X GET "$API_ENDPOINT" \
     -H "Authorization: Bearer $API_KEY" | jq .
