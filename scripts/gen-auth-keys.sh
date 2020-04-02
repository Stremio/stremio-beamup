#!/bin/sh
GITHUB_USER=Ivshti

curl --silent "https://github.com/$GITHUB_USER.keys" | while read key
do
	# environment= does not seem to be working...
	# "restrict" instead of "no-agent-forwarding,no-port-forwarding,no-x11-forwarding": this also disables the pty
	echo command=\"GITHUB_USER=\'$GITHUB_USER\' /tmp/script2.sh\",restrict $key
done

echo command=\"/tmp/script2.sh\",restrict `cat ./id_control_ed25519.pub`
