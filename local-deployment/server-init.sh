sudo apt-get update && sudo apt-get install -y gnupg software-properties-common



echo 'Adding repositories ...'

# Install HashiCorp's GPG key.

wget -O- https://apt.releases.hashicorp.com/gpg | \
gpg --dearmor | \
sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null

# Verify the GPG key's fingerprint.

$ gpg --no-default-keyring \
--keyring /usr/share/keyrings/hashicorp-archive-keyring.gpg \
--fingerprint

# The gpg command reports the key fingerprint:

# /usr/share/keyrings/hashicorp-archive-keyring.gpg
# -------------------------------------------------
# pub   rsa4096 XXXX-XX-XX [SC]
# AAAA AAAA AAAA AAAA
# uid         [ unknown] HashiCorp Security (HashiCorp Package Signing) <security+packaging@hashicorp.com>
# sub   rsa4096 XXXX-XX-XX [E]

# Add the official HashiCorp repository to your system.

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

# Add Ansible PPA
$ sudo add-apt-repository --yes --update ppa:ansible/ansible


# Update apt to download the package information from the HashiCorp repository.

sudo apt update

# Install Terraform from the new repository.

echo 'Installing dependencies ...'

sudo apt-get install qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils mkisofs terraform ansible -y


# Adding current user to libvirt

sudo usermod -a -G libvirt $(whoami)

# Setting up default libvirt storage pool
sudo virsh pool-define-as --name default --type dir --target /var/lib/libvirt/images
sudo virsh pool-build default
sudo virsh pool-start default
sudo virsh pool-autostart default

# install ansible dependencies

ansible-galaxy install -r ansible/requirements.yml --force
ansible-galaxy collection install -r ansible/requirements.yml --force