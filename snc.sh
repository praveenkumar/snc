#!/bin/bash

set -exuo pipefail

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

source tools.sh
source snc-library.sh

# kill all the child processes for this script when it exits
trap 'jobs=($(jobs -p)); [ -n "${jobs-}" ] && ((${#jobs})) && kill "${jobs[@]}" || true' EXIT

# If the user set OKD_VERSION in the environment, then use it to override OPENSHIFT_VERSION, MIRROR, and OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE
# Unless, those variables are explicitly set as well.
OKD_VERSION=${OKD_VERSION:-none}
BUNDLE_TYPE="snc"
if [[ ${OKD_VERSION} != "none" ]]
then
    OPENSHIFT_VERSION=${OKD_VERSION}
    MIRROR=${MIRROR:-https://github.com/okd-project/okd-scos/releases/download}
    BUNDLE_TYPE="okd"
fi

INSTALL_DIR=crc-tmp-install-data
SNC_PRODUCT_NAME=${SNC_PRODUCT_NAME:-crc}
SNC_CLUSTER_MEMORY=${SNC_CLUSTER_MEMORY:-14336}
SNC_CLUSTER_CPUS=${SNC_CLUSTER_CPUS:-6}
CRC_VM_DISK_SIZE=${CRC_VM_DISK_SIZE:-31}
BASE_DOMAIN=${CRC_BASE_DOMAIN:-testing}
CRC_PV_DIR="/mnt/pv-data"
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_ecdsa_crc"
SCP="scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_ecdsa_crc"
MIRROR=${MIRROR:-https://mirror.openshift.com/pub/openshift-v4/$ARCH/clients/ocp-dev-preview}
CERT_ROTATION=${SNC_DISABLE_CERT_ROTATION:-enabled}
USE_PATCHED_RELEASE_IMAGE=${SNC_USE_PATCHED_RELEASE_IMAGE:-disabled}
HTPASSWD_FILE='users.htpasswd'

run_preflight_checks ${BUNDLE_TYPE}

# If user defined the OPENSHIFT_VERSION environment variable then use it.
# Otherwise use the tagged version if available
if test -n "${OPENSHIFT_VERSION-}"; then
    OPENSHIFT_RELEASE_VERSION=${OPENSHIFT_VERSION}
    echo "Using release ${OPENSHIFT_RELEASE_VERSION} from OPENSHIFT_VERSION"
else
    OPENSHIFT_RELEASE_VERSION="$(curl -L "${MIRROR}"/candidate-4.15/release.txt | sed -n 's/^ *Version: *//p')"
    if test -n "${OPENSHIFT_RELEASE_VERSION}"; then
        echo "Using release ${OPENSHIFT_RELEASE_VERSION} from the latest mirror"
    else
        echo "Unable to determine an OpenShift release version. You may want to set the OPENSHIFT_VERSION environment variable explicitly."
        exit 1
    fi
fi

# Download the oc binary for specific OS environment
OC=./openshift-clients/linux/oc
download_oc

if test -z "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE-}"; then
    OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$(curl -L "${MIRROR}/${OPENSHIFT_RELEASE_VERSION}/release.txt" | sed -n 's/^Pull From: //p')"
elif test -n "${OPENSHIFT_VERSION-}"; then
    echo "Both OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE and OPENSHIFT_VERSION are set, OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE will take precedence"
    echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: $OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE"
    echo "OPENSHIFT_VERSION: $OPENSHIFT_VERSION"
fi
echo "Setting OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

# Extract openshift-install binary if not present in current directory
if test -z ${OPENSHIFT_INSTALL-}; then
    echo "Extracting OpenShift installer binary"
    ${OC} adm release extract -a ${OPENSHIFT_PULL_SECRET_PATH} ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} --command=openshift-install --to .
    OPENSHIFT_INSTALL=./openshift-install
fi

if [[ ${USE_PATCHED_RELEASE_IMAGE} == "enabled" ]]
then
   echo "Using release image with patched KAO/KCMO images"
   OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=quay.io/crcont/ocp-release:${OPENSHIFT_RELEASE_VERSION}-${yq_ARCH}
   echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE set to ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
fi

# Allow to disable debug by setting SNC_OPENSHIFT_INSTALL_NO_DEBUG in the environment
if test -z "${SNC_OPENSHIFT_INSTALL_NO_DEBUG-}"; then
        OPENSHIFT_INSTALL_EXTRA_ARGS="--log-level debug"
else
        OPENSHIFT_INSTALL_EXTRA_ARGS=""
fi
# Destroy an existing cluster and resources
${OPENSHIFT_INSTALL} --dir ${INSTALL_DIR} destroy cluster ${OPENSHIFT_INSTALL_EXTRA_ARGS} || echo "failed to destroy previous cluster.  Continuing anyway"
# Generate a new ssh keypair for this cluster
# Create a 521bit ECDSA Key
rm id_ecdsa_crc* || true
ssh-keygen -t ecdsa -b 521 -N "" -f id_ecdsa_crc -C "core"

# Use dnsmasq as dns in network manager config
if ! grep -iqR dns=dnsmasq /etc/NetworkManager/conf.d/ ; then
   cat << EOF | sudo tee /etc/NetworkManager/conf.d/crc-snc-nm-dnsmasq.conf
[main]
dns=dnsmasq
EOF
fi

# Clean up old DNS overlay file
if [ -f /etc/NetworkManager/dnsmasq.d/openshift.conf ]; then
    sudo rm /etc/NetworkManager/dnsmasq.d/openshift.conf
fi

destroy_libvirt_resources rhcos-live.iso
create_libvirt_resources

# Set NetworkManager DNS overlay file
cat << EOF | sudo tee /etc/NetworkManager/dnsmasq.d/crc-snc.conf
server=/${SNC_PRODUCT_NAME}.${BASE_DOMAIN}/192.168.126.1
address=/apps-${SNC_PRODUCT_NAME}.${BASE_DOMAIN}/192.168.126.11
EOF

# Reload the NetworkManager to make DNS overlay effective
sudo systemctl reload NetworkManager

if [[ ${CERT_ROTATION} == "enabled" ]]
then
    # Disable the network time sync and set the clock to past (for a day) on host
    sudo timedatectl set-ntp off
    sudo date -s '-1 day'
fi

# Create the INSTALL_DIR for the installer and copy the install-config
rm -fr ${INSTALL_DIR} && mkdir ${INSTALL_DIR} && cp install-config.yaml ${INSTALL_DIR}
${YQ} eval --inplace ".controlPlane.architecture = \"${yq_ARCH}\"" ${INSTALL_DIR}/install-config.yaml
${YQ} eval --inplace ".baseDomain = \"${BASE_DOMAIN}\"" ${INSTALL_DIR}/install-config.yaml
${YQ} eval --inplace ".metadata.name = \"${SNC_PRODUCT_NAME}\"" ${INSTALL_DIR}/install-config.yaml
replace_pull_secret ${INSTALL_DIR}/install-config.yaml
${YQ} eval ".sshKey = \"$(cat id_ecdsa_crc.pub)\"" --inplace ${INSTALL_DIR}/install-config.yaml

# Create the manifests using the INSTALL_DIR
OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE ${OPENSHIFT_INSTALL} --dir ${INSTALL_DIR} create manifests

# Add CVO overrides before first start of the cluster. Objects declared in this file won't be created.
${YQ} eval-all --inplace 'select(fileIndex == 0) * select(filename == "cvo-overrides.yaml")' ${INSTALL_DIR}/manifests/cvo-overrides.yaml cvo-overrides.yaml

# Add custom domain to cluster-ingress
${YQ} eval --inplace ".spec.domain = \"apps-${SNC_PRODUCT_NAME}.${BASE_DOMAIN}\"" ${INSTALL_DIR}/manifests/cluster-ingress-02-config.yml
# Add network resource to lower the mtu for CNV
cp cluster-network-03-config.yaml ${INSTALL_DIR}/manifests/
# Add patch to mask the chronyd service on master
cp 99_master-chronyd-mask.yaml $INSTALL_DIR/openshift/
# Add dummy network unit file
cp 99-openshift-machineconfig-master-dummy-networks.yaml $INSTALL_DIR/openshift/
# Add kubelet config resource to make change in kubelet
DYNAMIC_DATA=$(base64 -w0 node-sizing-enabled.env) envsubst < 99_master-node-sizing-enabled-env.yaml.in > $INSTALL_DIR/openshift/99_master-node-sizing-enabled-env.yaml
# Add codeReadyContainer as invoker to identify it with telemeter
export OPENSHIFT_INSTALL_INVOKER="codeReadyContainers"
export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig

OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE ${OPENSHIFT_INSTALL} --dir ${INSTALL_DIR} create single-node-ignition-config ${OPENSHIFT_INSTALL_EXTRA_ARGS}
# mask the chronyd service on the bootstrap node
cat <<< $(${JQ} '.systemd.units += [{"mask": true, "name": "chronyd.service"}]' ${INSTALL_DIR}/bootstrap-in-place-for-live-iso.ign) > ${INSTALL_DIR}/bootstrap-in-place-for-live-iso.ign

# Download the image
# https://docs.openshift.com/container-platform/4.14/installing/installing_sno/install-sno-installing-sno.html#install-sno-installing-sno-manually
# (Step retrieve the RHCOS iso url)
ISO_URL=$(OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE ${OPENSHIFT_INSTALL} coreos print-stream-json | grep location | grep $ARCH | grep iso | cut -d\" -f4)
curl -L ${ISO_URL} -o ${INSTALL_DIR}/rhcos-live.iso

podman run --privileged --pull always --rm \
      -v /dev:/dev -v /run/udev:/run/udev -v $PWD:/data \
      -w /data quay.io/coreos/coreos-installer:release \
      iso ignition embed --force \
      --ignition-file ${INSTALL_DIR}/bootstrap-in-place-for-live-iso.ign \
      ${INSTALL_DIR}/rhcos-live.iso

sudo mv -Z ${INSTALL_DIR}/rhcos-live.iso /var/lib/libvirt/${SNC_PRODUCT_NAME}/rhcos-live.iso
create_vm rhcos-live.iso

${OPENSHIFT_INSTALL} --dir ${INSTALL_DIR} wait-for install-complete ${OPENSHIFT_INSTALL_EXTRA_ARGS} || ${OC} adm must-gather --dest-dir ${INSTALL_DIR}

if [[ ${CERT_ROTATION} == "enabled" ]]
then
    renew_certificates
fi

# Wait for install to complete, this provide another 30 mins to make resources (apis) stable
${OPENSHIFT_INSTALL} --dir ${INSTALL_DIR} wait-for install-complete ${OPENSHIFT_INSTALL_EXTRA_ARGS}

# Set the VM static hostname to crc-xxxxx-master-0 instead of localhost.localdomain
HOSTNAME=$(${SSH} core@api.${SNC_PRODUCT_NAME}.${BASE_DOMAIN} hostnamectl status --transient)
${SSH} core@api.${SNC_PRODUCT_NAME}.${BASE_DOMAIN} sudo hostnamectl set-hostname ${HOSTNAME}

create_json_description ${BUNDLE_TYPE}

# Create persistent volumes
create_pvs ${BUNDLE_TYPE}

# Mark some of the deployments unmanaged by the cluster-version-operator (CVO)
# https://github.com/openshift/cluster-version-operator/blob/master/docs/dev/clusterversion.md#setting-objects-unmanaged
# Objects declared in this file are still created by the CVO at startup.
# The CVO won't modify these objects anymore with the following command. Hence, we can remove them afterwards.
retry ${OC} patch clusterversion version --type json -p "$(cat cvo-overrides-after-first-run.yaml)"

# Scale route deployment from 2 to 1
retry ${OC} scale --replicas=1 ingresscontroller/default -n openshift-ingress-operator

# Set default route for registry CRD from false to true.
retry ${OC} patch config.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge

# Add a tip in the login page
secret_template=$(retry ${OC} get secrets -n openshift-authentication v4-0-config-system-ocp-branding-template -o json)
${JQ} -r '.data["login.html"]' <(echo "${secret_template}") | base64 -d > login.html
${PATCH} login.html < login.html.patch
retry ${OC} create secret generic login-template --from-file=login.html -n openshift-config

# Generate the htpasswd file to have admin and developer user
generate_htpasswd_file ${INSTALL_DIR} ${HTPASSWD_FILE}

# Add a user developer with htpasswd identity provider and give it sudoer role
# Add kubeadmin user with cluster-admin role
retry ${OC} create secret generic htpass-secret --from-file=htpasswd=${HTPASSWD_FILE} -n openshift-config
retry ${OC} apply -f oauth_cr.yaml
retry ${OC} create clusterrolebinding kubeadmin --clusterrole=cluster-admin --user=kubeadmin

# Remove temp kubeadmin user
retry ${OC} delete secrets kubeadmin -n kube-system

# Add security message on the web console
retry ${OC} create -f security-notice.yaml

# Remove the Cluster ID with a empty string.
retry ${OC} patch clusterversion version -p '{"spec":{"clusterID":""}}' --type merge

# SCP the kubeconfig file to VM
${SCP} ${KUBECONFIG} core@api.${SNC_PRODUCT_NAME}.${BASE_DOMAIN}:/home/core/
${SSH} core@api.${SNC_PRODUCT_NAME}.${BASE_DOMAIN} -- 'sudo mv /home/core/kubeconfig /opt/'

# Add exposed registry CA to VM
retry ${OC} extract secret/router-ca --keys=tls.crt -n openshift-ingress-operator --confirm
retry ${OC} create configmap registry-certs --from-file=default-route-openshift-image-registry.apps-${SNC_PRODUCT_NAME}.${BASE_DOMAIN}=tls.crt -n openshift-config
retry ${OC} patch image.config.openshift.io cluster -p '{"spec": {"additionalTrustedCA": {"name": "registry-certs"}}}' --type merge

# Remove the machine config for chronyd to make it active again
retry ${OC} delete mc chronyd-mask

# Wait for the cluster again to become stable because of all the patches/changes
wait_till_cluster_stable

mc_before_removing_pullsecret=$(retry ${OC} get mc --sort-by=.metadata.creationTimestamp --no-headers -oname)
# Replace pull secret with a null json string '{}'
retry ${OC} replace -f pull-secret.yaml
mc_after_removing_pullsecret=$(retry ${OC} get mc --sort-by=.metadata.creationTimestamp --no-headers -oname)

while [ "${mc_before_removing_pullsecret}" == "${mc_after_removing_pullsecret}" ]; do
	echo "Machine config is still not rendered"
	mc_after_removing_pullsecret=$(retry ${OC} get mc --sort-by=.metadata.creationTimestamp --no-headers -oname)
done

wait_till_cluster_stable openshift-marketplace

# Delete the pods which are there in Complete state
retry ${OC} delete pod --field-selector=status.phase==Succeeded --all-namespaces

# Delete outdated rendered master/worker machineconfigs and just keep the latest one
mc_name=$(retry ${OC} get mc --sort-by=.metadata.creationTimestamp --no-headers -oname)
echo "${mc_name}" | grep rendered-master | head -n -1 | xargs -t ${OC} delete
echo "${mc_name}" | grep rendered-worker | head -n -1 | xargs -t ${OC} delete
# Wait till machine config pool is updated correctly
while retry ${OC} get mcp master -ojsonpath='{.status.conditions[?(@.type!="Updated")].status}' | grep True; do
    echo "Machine config still in updating/degrading state"
done

# Create a container from baremetal-runtimecfg image which consumed by nodeip-configuration service so it is
# not deleted by `crictl rmi --prune` command
BAREMETAL_RUNTIMECFG=$(${OC} adm release info -a ${OPENSHIFT_PULL_SECRET_PATH} ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} --image-for=baremetal-runtimecfg)
${SSH} core@api.${SNC_PRODUCT_NAME}.${BASE_DOMAIN} -- "sudo podman create --name baremetal_runtimecfg ${BAREMETAL_RUNTIMECFG}"

# Remove unused images from container storage
${SSH} core@api.${SNC_PRODUCT_NAME}.${BASE_DOMAIN} -- 'sudo crictl rmi --prune'

# Remove the baremetal_runtimecfg container which is temp created
${SSH} core@api.${SNC_PRODUCT_NAME}.${BASE_DOMAIN} -- "sudo podman rm baremetal_runtimecfg"
