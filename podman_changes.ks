# This file is used as part of microshift VM creation
# to have podman specific configuration in place which
# we do using ignition for podman bundle

# Make podman rootless available
mkdir -p /home/core/.config/systemd/user/default.target.wants
ln -s /usr/lib/systemd/user/podman.socket /home/core/.config/systemd/user/default.target.wants/podman.socket
chown -R core:core /home/core/.config

mkdir -p /home/core/.config/containers
tee /home/core/.config/containers/containers.conf <<EOF
[containers]
netns="bridge"
rootless_networking="cni"
EOF
chown -R core:core /home/core/.config/containers

tee /etc/containers/containers.conf <<EOF
[engine]
machine_enabled=true
EOF

tee /etc/containers/registries.conf.d/999-podman-machine.conf <<EOF
unqualified-search-registries=["docker.io"]
EOF

