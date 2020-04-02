#!/bin/sh
GITHUB_USER=Ivshti

curl --silent https://github.com/$GITHUB_USER.keys | while read key
do
	# environment= does not seem to be working...
	echo command=\"/tmp/script2.sh $GITHUB_USER\",restrict,pty $key
done
