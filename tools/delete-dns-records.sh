#!/bin/bash

# Check if an argument is provided
if [ "$#" -ne 1 ]; then
  echo "Usage: ./tools/delete-dns-records.sh TARGET_IP_ADDRESS"
  echo "And remember to do backup/export of DNS of CloudFlare first!"
  exit 1
fi

# VARS
API_TOKEN=$(cat creds/cloudflare_token) # Token that has DNS permissions over Zone
ZONE_ID=$(cat creds/cloudflare_zone_id) # Zone ID
TARGET_IP_ADDRESS=$1  # Use the first argument as the target IP address

# Get Zone Name
zone_info=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID" \
     -H "Authorization: Bearer $API_TOKEN" \
     -H "Content-Type: application/json")

zone_name=$(echo $zone_info | jq -r '.result.name')

# List DNS Records
# Check there is a max with the per_page parameter
response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?per_page=500" \
     -H "Authorization: Bearer $API_TOKEN" \
     -H "Content-Type: application/json")
#To debug response
#echo $response

# Extract and display Record IDs, Names, and IPs with jq tool
echo "Records to be deleted in zone $zone_name:"
record_info=$(echo $response | jq -r ".result[] | select(.content==\"$TARGET_IP_ADDRESS\") | \"ID: \(.id) - Name: \(.name) - IP: \(.content)\"")
echo "$record_info"

# Confirm action
read -p "Are you sure you want to delete these DNS records? [y/N] " confirmation
if [[ ! "$confirmation" =~ ^[Yy]$ ]]
then
  exit 1
fi

# Delete records
echo $response | jq -r ".result[] | select(.content==\"$TARGET_IP_ADDRESS\") | .id" | while read -r record_id; do
  record_name=$(echo $response | jq -r ".result[] | select(.id==\"$record_id\") | .name")
  echo "Deleting $record_name ($record_id)"
  deletion_response=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$record_id" \
       -H "Authorization: Bearer $API_TOKEN" \
       -H "Content-Type: application/json")
  echo "Deletion response: $deletion_response"
done
