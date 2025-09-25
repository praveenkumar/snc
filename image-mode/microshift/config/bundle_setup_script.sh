#!/bin/bash

set -exuo pipefail

export LC_ALL=C
export LANG=C

# Get bundle type and other parameters from environment or command line
BUNDLE_TYPE=${BUNDLE_TYPE:-"microshift"}
OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-""}
SNC_PRODUCT_NAME=${SNC_PRODUCT_NAME:-"crc"}
BASE_DOMAIN=${BASE_DOMAIN:-"testing"}
ARCH=${ARCH:-$(uname -m)}

# Common setup for all bundle types
echo -e 'core\tALL=(ALL)\tNOPASSWD: ALL' > /etc/sudoers.d/microshift

echo "${SNC_PRODUCT_NAME}" > /etc/hostname
chmod 644 /etc/hostname

# Enable linger for core user to make sure podman socket work when user not logged in
mkdir -p /var/lib/systemd/linger/
touch /var/lib/systemd/linger/core

function embed_image() {
    local image=$1
    local additional_copy_args=${2:-""}

    mkdir -p /usr/lib/containers-image-cache
    sha=$(echo "$image" | sha256sum | awk '{ print $1 }')
    skopeo copy $additional_copy_args --preserve-digests docker://$image dir:/usr/lib/containers-image-cache/$sha
    echo "$image,$sha" >> /usr/lib/containers-image-cache/mapping.txt
}

# 1. Enable podman socket services for API V2
echo "Enabling podman socket services..."
systemctl enable podman.socket
systemctl --user enable podman.socket


echo "Applying microshift-specific configuration..."
# Pre-pull OpenShift release images
echo "Pre-loading OpenShift release images..."
jq --raw-output '.images | to_entries | map(.value) | join("\n")' /usr/share/microshift/release/release-$(uname -i).json | while read -r image; do embed_image "$image" "--authfile /etc/crio/openshift-pull-secret"; done

# Disable firewalld
echo "Disabling firewalld..."
systemctl disable firewalld

# Validate baseDomain configuration
echo "Dropping in file for microshift base domain..."
# Drop in file for microshift base domain
cat > /etc/microshift/config.d/00-microshift-dns.yaml <<EOF
dns:
   baseDomain: ${SNC_PRODUCT_NAME}.${BASE_DOMAIN}
node:
  hostnameOverride: "api.${SNC_PRODUCT_NAME}.${BASE_DOMAIN}"
EOF

# Remove LVM system devices file
echo "Removing LVM system devices file..."
rm -fr /etc/lvm/devices/system.devices


# 4. Create tap device interface with specified MAC address
echo "Creating tap device network interface..."
tee /etc/NetworkManager/system-connections/tap0.nmconnection <<EOF
[connection]
id=tap0
uuid=c2fd153c-4d6e-496d-acdc-e197b609421b
type=tun
interface-name=tap0

[ethernet]
cloned-mac-address=5A:94:EF:E4:0C:EE

[tun]
mode=2

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=disabled

[proxy]
EOF

chmod 600 /etc/NetworkManager/system-connections/tap0.nmconnection

# 5. Add gvisor-tap-vsock service
echo "Setting up gvisor-tap-vsock service..."
tee /etc/systemd/system/gv-user-network@.service <<EOF
[Unit]
Description=gvisor-tap-vsock Network Traffic Forwarder
After=sys-devices-virtual-net-%i.device

[Service]
Restart=on-failure
Environment="GV_VSOCK_PORT=1024"
EnvironmentFile=-/etc/sysconfig/gv-user-network
ExecCondition=/bin/sh -c '! /usr/local/bin/crc-check-cloud-env.sh'
ExecStartPre=/bin/sh -c 'for i in {1..10}; do ip link show "\$1" && exit 0; sleep 1; done; exit 1' _ %i
ExecStart=/usr/libexec/podman/gvforwarder -preexisting -iface %i -url vsock://2:"\${GV_VSOCK_PORT}"/connect

[Install]
WantedBy=multi-user.target
EOF

systemctl enable gv-user-network@tap0.service

# 6. Setup copy embedded images service
echo "Setting up copy embedded images service..."
tee /etc/systemd/system/copy_embedded_images.service <<EOF
[Unit]
Description=Copy Embedded Images to Container Storage
Wants=multi-user.target
After=multi-user.target
Before=crio.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/copy_embedded_images.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# The copy embedded images script is already installed by the Containerfile
systemctl enable copy_embedded_images.service

# 7. Setup routes controller
echo "Setting up routes controller..."
image_tag="latest"
if podman manifest inspect quay.io/crcont/routes-controller:${OPENSHIFT_VERSION} >/dev/null 2>&1; then
    image_tag=${OPENSHIFT_VERSION}
fi

echo "Embedding routes controller image with tag: ${image_tag}"
embed_image "quay.io/crcont/routes-controller:${image_tag}"
mkdir -p /opt/crc
tee /opt/crc/routes-controller.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: routes-controller
  name: routes-controller
  namespace: openshift-ingress
spec:
  replicas: 1
  selector:
    matchLabels:
      app: routes-controller
  template:
    metadata:
      labels:
        app: routes-controller
    spec:
      serviceAccountName: router
      containers:
      - image: quay.io/crcont/routes-controller:${image_tag}
        name: routes-controller
        imagePullPolicy: IfNotPresent
EOF

echo "Setting up x86 emulation packages for ARM64..."
    
# Create temporary fedora-updates repo
tee /etc/yum.repos.d/fedora-updates.repo <<EOF
[fedora-updates]
name=Fedora 41 - \$basearch - Updates
metalink=https://mirrors.fedoraproject.org/metalink?repo=updates-released-f41&arch=\$basearch
enabled=1
type=rpm
repo_gpgcheck=0
gpgcheck=0
EOF

# Install qemu-user-static-x86 package
dnf install -y qemu-user-static-x86

# Clean up temporary repo
rm -fr /etc/yum.repos.d/fedora-updates.repo

dnf install -y cloud-init gvisor-tap-vsock-gvforwarder

# 10. Enable cloud-init services
echo "Enabling cloud-init services..."
systemctl enable cloud-init cloud-config cloud-final

# 12. Configure cloud-init network settings
echo "Configuring cloud-init network settings..."
tee /etc/cloud/cloud.cfg.d/05_disable-network.cfg <<EOF
network:
    config: disabled
EOF

# 13. Configure cloud-init hostname preservation
echo "Configuring cloud-init hostname preservation..."
sed -i "s/^preserve_hostname: false$/preserve_hostname: true/" /etc/cloud/cloud.cfg

# 14. Clean up cloud-init configuration
echo "Cleaning up cloud-init configuration..."
cloud-init clean --logs
