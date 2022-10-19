#!/bin/bash

set -exuo pipefail

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

source tools.sh
source snc-library.sh

BUNDLE_TYPE="microshift"
INSTALL_DIR=crc-tmp-install-data
CRC_VM_NAME=${CRC_VM_NAME:-crc}
BASE_DOMAIN=${CRC_BASE_DOMAIN:-testing}
MIRROR=${MIRROR:-https://mirror.openshift.com/pub/openshift-v4/$ARCH/clients/ocp}
OPENSHIFT_RELEASE_VERSION=4.12.0

if grep -q -i "release 9" /etc/redhat-release
then
  echo "Check if system is registered"
  # Check the subscription status and register if necessary
  if ! sudo subscription-manager status >& /dev/null ; then
     sudo subscription-manager register
  fi
else
  echo "This script only works for RHEL-9"
fi

run_preflight_checks ${BUNDLE_TYPE}
rm -fr ${INSTALL_DIR} && mkdir ${INSTALL_DIR}

sudo virsh destroy ${CRC_VM_NAME} || true
sudo virsh undefine --nvram ${CRC_VM_NAME} || true
sudo rm -fr /var/lib/libvirt/images/${CRC_VM_NAME}.qcow2
sudo rm -fr /var/lib/libvirt/images/microshift-installer-*.iso

# Download the oc binary for specific OS environment
OC=./openshift-clients/linux/oc
download_oc

# Generate a new ssh keypair for this cluster
# Create a 521bit ECDSA Key
rm id_ecdsa_crc* || true
ssh-keygen -t ecdsa -b 521 -N "" -f id_ecdsa_crc -C "core"

# Configure host (RHEL-9) with required internal repo
sudo tee /etc/yum.repos.d/latest-fdp.repo >/dev/null <<EOF
[latest-FDP]
name = latest-FDP-Buildroot-rpms
baseurl = http://download.eng.bos.redhat.com/rhel-9/nightly/FDP/latest-FDP-9-RHEL-9/compose/Server/\$basearch/os/
enabled = 1
gpgcheck = 0
EOF
sudo tee /etc/yum.repos.d/latest-rhaos.repo >/dev/null <<EOF
[latest-RHAOS]
name = latest-RHAOS-puddle
baseurl = http://download.lab.bos.redhat.com/rcm-guest/puddles/RHAOS/plashets/4.12-el9/building/\$basearch/os/
enabled = 1
gpgcheck = 0
EOF

rm -fr microshift
# Clone microshift repo
git clone -b release-4.12 https://github.com/openshift/microshift.git
cp podman_changes.ks microshift/
pushd microshift
sudo chmod 0755 $HOME
ssh-keygen -t ecdsa -b 521 -N "" -f id_ecdsa_crc -C "core"
sed -i '/# customizations/,$d' scripts/image-builder/config/blueprint_v0.0.1.toml
cat << EOF >> scripts/image-builder/config/blueprint_v0.0.1.toml
[[packages]]
name = "microshift-release-info"
version = "*"
EOF
sed -i 's/redhat/core/g' scripts/image-builder/config/kickstart.ks.template
sed -i '/--bootproto=dhcp/a\network  --hostname=api.crc.testing' scripts/image-builder/config/kickstart.ks.template
sed -i '$e cat podman_changes.ks' scripts/image-builder/config/kickstart.ks.template
sed -i 's/epel-release-latest-8.noarch/epel-release-latest-9.noarch/g' scripts/image-builder/configure.sh
sed -i 's/rhocp-4.12-for-rhel-8-\${BUILD_ARCH}-rpms/latest-RHAOS/g' scripts/image-builder/build.sh
sed -i 's/fast-datapath-for-rhel-8-\${BUILD_ARCH}-rpms/latest-FDP/g' scripts/image-builder/build.sh
scripts/image-builder/configure.sh
scripts/image-builder/cleanup.sh -full
make rpm
scripts/image-builder/build.sh -pull_secret_file ${OPENSHIFT_PULL_SECRET_PATH} -authorized_keys_file $(realpath ../id_ecdsa_crc.pub)
OPENSHIFT_RELEASE_VERSION=$(jq -r '.release.base' assets/release/release-$(uname -i).json)
popd
sudo mv microshift/_output/image-builder/microshift-installer-*.iso /var/lib/libvirt/images/

create_json_description ${BUNDLE_TYPE}

# For microshift we create a empty kubeconfig file
# to have it as part of bundle
mkdir -p ${INSTALL_DIR}/auth
touch ${INSTALL_DIR}/auth/kubeconfig

# Start the VM with generated ISO
sudo virt-install \
    --name ${CRC_VM_NAME} \
    --vcpus 2 \
    --memory 2048 \
    --arch=${ARCH} \
    --disk path=/var/lib/libvirt/images/${CRC_VM_NAME}.qcow2,size=31 \
    --network network=default,model=virtio \
    --nographics \
    --cdrom /var/lib/libvirt/images/microshift-installer-*.iso \
    --events on_reboot=restart \
    --autoconsole none \
    --wait

# Sleep for 3 mins because after starting the vm, kickstart file takes time to
# install from iso
sleep 180
