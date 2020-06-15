[Unit]
Description=Setup a secure tunnel to the beamup swarm
After=network.target

[Service]
ExecStart=/usr/bin/ssh -i /home/dokku/.ssh/id_ed25519 -NT -o ServerAliveInterval=60 -o ExitOnForwardFailure=yes -L 5000:127.0.0.1:5000 ${username}@${target}

# Restart every >2 seconds to avoid StartLimitInterval failure
RestartSec=5
Restart=always

[Install]
WantedBy=multi-user.target
