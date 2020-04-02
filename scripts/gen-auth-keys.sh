#!/bin/sh
GITHUB_USER=Ivshti
set -e
KEYS=`curl --silent "https://github.com/$GITHUB_USER.keys"`
( echo $KEYS | while read SSH_KEY
do
	# environment= does not seem to be working...
	# "restrict" instead of "no-agent-forwarding,no-port-forwarding,no-x11-forwarding": this also disables the pty
	# the PTY is not needed cause we don't need anything interactive
	echo "command=\"GITHUB_USER='$GITHUB_USER' /tmp/script2.sh \$SSH_ORIGINAL_COMMAND\",restrict $SSH_KEY"
done ) && echo command=\"/tmp/script2.sh\",restrict `cat ./id_control_ed25519.pub`
