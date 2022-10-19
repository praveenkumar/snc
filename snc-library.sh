#!/bin/bash

set -exuo pipefail

function preflight_failure() {
        local msg=$1
        echo "$msg"
        if [ -z "${SNC_NON_FATAL_PREFLIGHT_CHECKS-}" ]; then
                exit 1
        fi
}

function check_oc_version() {
    local current_oc_version=
    if [ -f "$OC" ]; then
       current_oc_version=$(${OC} version --client -o json  |jq -r .releaseClientVersion)
    fi

    [ ${current_oc_version} = ${OPENSHIFT_RELEASE_VERSION} ]
}

function download_oc() {
    local current_oc_version=

    if [ -f "$OC" ]; then
        current_oc_version=$(${OC} version --client -o json  |jq -r .releaseClientVersion)
        if [ ${current_oc_version} = ${OPENSHIFT_RELEASE_VERSION} ]; then
            echo "No need to download oc, local oc is already version ${OPENSHIFT_RELEASE_VERSION}"
            return
        fi
    fi

    mkdir -p openshift-clients/linux
    curl -L "${MIRROR}/${OPENSHIFT_RELEASE_VERSION}/openshift-client-linux-${OPENSHIFT_RELEASE_VERSION}.tar.gz" | tar -zx -C openshift-clients/linux oc

    if [ -n "${SNC_GENERATE_MACOS_BUNDLE}" ]; then
        mkdir -p openshift-clients/mac
        # workaround for https://github.com/code-ready/snc/issues/576
        curl -L "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.10/openshift-client-mac.tar.gz" | tar -zx -C openshift-clients/mac oc
    fi
    if [ -n "${SNC_GENERATE_WINDOWS_BUNDLE}" ]; then
        mkdir -p openshift-clients/windows
        curl -L "${MIRROR}/${OPENSHIFT_RELEASE_VERSION}/openshift-client-windows-${OPENSHIFT_RELEASE_VERSION}.zip" > openshift-clients/windows/oc.zip
        ${UNZIP} -o -d openshift-clients/windows/ openshift-clients/windows/oc.zip
    fi
}

function run_preflight_checks() {
	local preset=${1:-snc}
        if [ -z "${OPENSHIFT_PULL_SECRET_PATH-}" ]; then
            echo "OpenShift pull secret file path must be specified through the OPENSHIFT_PULL_SECRET_PATH environment variable"
            exit 1
        elif [ ! -f ${OPENSHIFT_PULL_SECRET_PATH} ]; then
            echo "Provided OPENSHIFT_PULL_SECRET_PATH (${OPENSHIFT_PULL_SECRET_PATH}) does not exists"
            exit 1
        fi

        echo "Checking libvirt and DNS configuration"

	LIBVIRT_URI=qemu:///system
	if [ ${preset} == "snc" ]; then
           LIBVIRT_URI=qemu+tcp://localhost/system
	fi

        # check if libvirtd is listening on a TCP socket
	if [ ${preset} == "snc" ]; then
            if ! virsh -c ${LIBVIRT_URI} uri >/dev/null; then
                    preflight_failure  "libvirtd is not listening for plain-text TCP connections, see https://github.com/openshift/installer/tree/master/docs/dev/libvirt#configure-libvirt-to-accept-tcp-connections"
            fi
	fi

	if ! virsh -c ${LIBVIRT_URI} net-info default &> /dev/null; then
		echo "Installing libvirt default network configuration"
		sudo dnf install -y libvirt-daemon-config-network || exit 1
	fi
	echo "default libvirt network is available"

	#Check if default libvirt network is Active
	if [[ $(virsh -c ${LIBVIRT_URI}  net-info default | awk '{print $2}' | sed '3q;d') == "no" ]]; then
		echo "Default network is not active, starting it"
		sudo virsh -c ${LIBVIRT_URI} net-start default || exit 1
	fi

	#Just warn if architecture is not supported
	case $ARCH in
		x86_64|ppc64le|s390x|aarch64)
			echo "The host arch is ${ARCH}.";;
		*)
 			echo "The host arch is ${ARCH}. This is not supported by SNC!";;
	esac

        # check for availability of a hypervisor using kvm
        if ! virsh -c ${LIBVIRT_URI} capabilities | ${XMLLINT} --xpath "/capabilities/guest/arch[@name='${ARCH}']/domain[@type='kvm']" - &>/dev/null; then
                preflight_failure "Your ${ARCH} platform does not provide a hardware-accelerated hypervisor, it's strongly recommended to enable it before running SNC. Check virt-host-validate for more detailed diagnostics"
                return
        fi

        # check that api.${CRC_VM_NAME}.${BASE_DOMAIN} either can't be resolved, or resolves to 192.168.126.1[01]
	if [ ${preset} == "snc" ]; then
            local ping_status
            ping_status="$(ping -c1 api.${CRC_VM_NAME}.${BASE_DOMAIN} | head -1 || true >/dev/null)"
            if echo ${ping_status} | grep "PING api.${CRC_VM_NAME}.${BASE_DOMAIN} (" && ! echo ${ping_status} | grep "192.168.126.1[01])"; then
                    preflight_failure "DNS setup seems wrong, api.${CRC_VM_NAME}.${BASE_DOMAIN} resolved to an IP which is neither 192.168.126.10 nor 192.168.126.11, please check your NetworkManager configuration and /etc/hosts content"
                    return
            fi
	fi

        # check if firewalld is configured to allow traffic from 192.168.126.0/24 to 192.168.122.1
        # this check is very basic and expects the configuration to match
        # https://github.com/openshift/installer/tree/master/docs/dev/libvirt#firewalld
        # Disabled for now as on stock RHEL8 installs, additional permissions are needed for
        # firewall-cmd --list-services, so this test fails for unrelated reasons
        #
        #local zone
        #if firewall-cmd -h >/dev/null; then
        #        # With older libvirt, the 'libvirt' zone will not exist
        #        if firewall-cmd --get-zones |grep '\<libvirt\>'; then
        #                zone=libvirt
        #        else
        #                zone=dmz
        #        fi
        #        if ! firewall-cmd --zone=${zone} --list-services | grep '\<libvirt\>'; then
        #                preflight_failure "firewalld is available, but it is not configured to allow 'libvirt' traffic in either the 'libvirt' or 'dmz' zone, please check https://github.com/openshift/installer/tree/master/docs/dev/libvirt#firewalld"
        #                return
        #        fi
        #fi

        echo "libvirt and DNS configuration successfully checked"
}

function replace_pull_secret() {
        # Hide the output of 'cat $OPENSHIFT_PULL_SECRET_PATH' so that it doesn't
        # get leaked in CI logs
        set +x
        local filename=$1
	pull_secret="$(< $OPENSHIFT_PULL_SECRET_PATH)" ${YQ} eval --inplace '.pullSecret = strenv(pull_secret) | .pullSecret style="literal"' $filename
        set -x
}

function create_json_description {
    openshiftInstallerVersion=$(${OPENSHIFT_INSTALL} version)
    sncGitHash=$(git describe --abbrev=4 HEAD 2>/dev/null || git rev-parse --short=4 HEAD)
    echo {} | ${JQ} '.version = "1.4"' \
            | ${JQ} ".type = \"${BUNDLE_TYPE}\"" \
            | ${JQ} ".arch = \"${yq_ARCH}\"" \
            | ${JQ} ".buildInfo.buildTime = \"$(date -u --iso-8601=seconds)\"" \
            | ${JQ} ".buildInfo.openshiftInstallerVersion = \"${openshiftInstallerVersion}\"" \
            | ${JQ} ".buildInfo.sncVersion = \"git${sncGitHash}\"" \
            | ${JQ} ".clusterInfo.openshiftVersion = \"${OPENSHIFT_RELEASE_VERSION}\"" \
            | ${JQ} ".clusterInfo.clusterName = \"${CRC_VM_NAME}\"" \
            | ${JQ} ".clusterInfo.baseDomain = \"${BASE_DOMAIN}\"" \
            | ${JQ} ".clusterInfo.appsDomain = \"apps-${CRC_VM_NAME}.${BASE_DOMAIN}\"" >${INSTALL_DIR}/crc-bundle-info.json
}


function create_pvs() {
    local bundle_type=$1

    # Create hostpath-provisioner namespace
    retry ${OC} apply -f kubevirt-hostpath-provisioner-csi/namespace.yaml
    # Add external provisioner RBACs
    retry ${OC} apply -f kubevirt-hostpath-provisioner-csi/external-provisioner-rbac.yaml -n hostpath-provisioner
    # Create CSIDriver/kubevirt.io.hostpath-provisioner resource
    retry ${OC} apply -f kubevirt-hostpath-provisioner-csi/csi-driver-hostpath-provisioner.yaml -n hostpath-provisioner
    # Apply SCC allowin hostpath-provisioner containers to run as root and access host network
    retry ${OC} apply -f kubevirt-hostpath-provisioner-csi/kubevirt-hostpath-security-constraints-csi.yaml

    # Deploy csi driver components
    if [[ ${bundle_type} == "snc" ]]; then
        # in case of OCP we want the images to come from registry.redhat.io
        # this is done using the kustomize.yaml file
        retry ${OC} apply -k kubevirt-hostpath-provisioner-csi/csi-driver -n hostpath-provisioner
    else
        retry ${OC} apply -f kubevirt-hostpath-provisioner-csi/csi-driver/csi-kubevirt-hostpath-provisioner.yaml -n hostpath-provisioner
    fi

    # create StorageClass crc-csi-hostpath-provisioner
    retry ${OC} apply -f kubevirt-hostpath-provisioner-csi/csi-sc.yaml

    # Apply registry pvc with crc-csi-hostpath-provisioner StorageClass
    retry ${OC} apply -f registry_pvc.yaml

    # Add registry storage to pvc
    retry ${OC} patch config.imageregistry.operator.openshift.io/cluster --patch='[{"op": "add", "path": "/spec/storage/pvc", "value": {"claim": "crc-image-registry-storage"}}]' --type=json
    # Remove emptyDir as storage for registry
    retry ${OC} patch config.imageregistry.operator.openshift.io/cluster --patch='[{"op": "remove", "path": "/spec/storage/emptyDir"}]' --type=json
}

# This follows https://blog.openshift.com/enabling-openshift-4-clusters-to-stop-and-resume-cluster-vms/
# in order to trigger regeneration of the initial 24h certs the installer created on the cluster
function renew_certificates() {
    local vm_prefix
    vm_prefix=$(get_vm_prefix ${CRC_VM_NAME})
    shutdown_vm ${vm_prefix}-master-0

    # Enable the network time sync and set the clock back to present on host
    sudo date -s '1 day'
    sudo timedatectl set-ntp on

    start_vm ${vm_prefix}-master-0 api.${CRC_VM_NAME}.${BASE_DOMAIN}

    # Loop until the kubelet certs are valid for a month
    i=0
    while [ $i -lt 60 ]; do
        if ! ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo openssl x509 -checkend 2160000 -noout -in /var/lib/kubelet/pki/kubelet-client-current.pem ||
		! ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo openssl x509 -checkend 2160000 -noout -in /var/lib/kubelet/pki/kubelet-server-current.pem; then
            retry ${OC} get csr -ojson > certs.json
	    retry ${OC} adm certificate approve -f certs.json
	    rm -f certs.json
	    echo "Retry loop $i, wait for 10sec before starting next loop"
            sleep 10
	else
            break
        fi
	i=$[$i+1]
    done

    if ! ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo openssl x509 -checkend 2160000 -noout -in /var/lib/kubelet/pki/kubelet-client-current.pem; then
        echo "kubelet client certs are not yet rotated to have 30 days validity"
	exit 1
    fi

    if ! ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} -- sudo openssl x509 -checkend 2160000 -noout -in /var/lib/kubelet/pki/kubelet-server-current.pem; then
        echo "kubelet server certs are not yet rotated to have 30 days validity"
	exit 1
    fi
}

# deletes an operator and wait until the resources it manages are gone.
function delete_operator() {
        local delete_object=$1
        local namespace=$2
        local pod_selector=$3

        retry ${OC} get pods
        pod=$(${OC} get pod -l ${pod_selector} -o jsonpath="{.items[0].metadata.name}" -n ${namespace})

        retry ${OC} delete ${delete_object} -n ${namespace}
        # Wait until the operator pod is deleted before trying to delete the resources it manages
        ${OC} wait --for=delete pod/${pod} --timeout=120s -n ${namespace} || ${OC} delete pod/${pod} --grace-period=0 --force -n ${namespace} || true
}

function all_operators_available() {
    # Check the cluster operator output, status for available should be true for all operators
    # The single line oc get co output should not contain any occurrences of `False`
    ${OC} get co -ojsonpath='{.items[*].status.conditions[?(@.type=="Available")].status}' | grep -v False
}

function no_operators_progressing() {
    # Check the cluster operator output, status for progressing should be false for all operators
    # The single line oc get co output should not contain any occurrences of `True`
    ${OC} get co -ojsonpath='{.items[*].status.conditions[?(@.type=="Progressing")].status}' | grep -v True
}

function no_operators_degraded() {
    # Check the cluster operator output, status for available should be false for all operators
    # The single line oc get co output should not contain any occurrences of `True`
    ${OC} get co -ojsonpath='{.items[*].status.conditions[?(@.type=="Degraded")].status}' | grep -v True
}

function all_pods_are_running_completed() {
    local ignoreNamespace=$1
    ! ${OC} get pod --no-headers --all-namespaces --field-selector=metadata.namespace!="${ignoreNamespace}" | grep -v Running | grep -v Completed
}

function wait_till_cluster_stable() {
    sleep 1m

    local retryCount=30
    local numConsecutive=3
    local count=0
    local ignoreNamespace=${1:-"none"}

    # Remove all the failed Pods
    retry ${OC} delete pods --field-selector=status.phase=Failed -A

    local a=0
    while [ $a -lt $retryCount ]; do
       if all_operators_available && no_operators_progressing && no_operators_degraded; then
           echo "All operators are available. Ensuring stability ..."
           count=$((count + 1))
       else
           echo "Some operators are still not available"
           count=0
       fi
       if [ $count -eq $numConsecutive ]; then
           echo "Cluster has stabilized"
           retry ${OC} delete pods --field-selector=status.phase=Failed -A
           break
       fi
       sleep 30s
       a=$((a + 1))
    done

    # Wait till all the pods are either running or complete state
    retry all_pods_are_running_completed "${ignoreNamespace}"
}

