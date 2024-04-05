#!/bin/bash
# https://api.cherryservers.com/doc/

# Check if at least the endpoint URL was provided as an argument
if [ $# -lt 1 ]; then
  echo "Usage: $0 <API_ENDPOINT> [QUERY_PARAMETERS...]"
  echo "Example:"
  echo "./tools/get-cherryservers-api.sh https://api.cherryservers.com/v1/teams \"page=2\" \"limit=10\""
  exit 1
fi

# Read the API key from the file
API_KEY=$(cat creds/cherryservers)

# Extract the endpoint URL from the first argument
API_ENDPOINT="$1"

# Shift the arguments so we can process any remaining ones as query parameters
shift

# Initialize query parameters
QUERY_PARAMS=""

# Loop through remaining arguments (if any) and append them as query parameters
for param in "$@"; do
  # Append the parameter to the query string, starting with ? for the first one and & for subsequent ones
  if [[ -z "$QUERY_PARAMS" ]]; then
    QUERY_PARAMS="?${param}"
  else
    QUERY_PARAMS="${QUERY_PARAMS}&${param}"
  fi
done

# Make a GET request to the API endpoint with curl, appending any query parameters
curl -s -X GET "${API_ENDPOINT}${QUERY_PARAMS}" \
     -H "Authorization: Bearer $API_KEY" | jq .
