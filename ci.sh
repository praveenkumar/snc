#!/bin/bash

set -exuo pipefail

sudo yum install -y podman make golang rsync

cat > /tmp/ignoretests.txt << EOF
[sig-apps] Daemon set [Serial] should rollback without unnecessary restarts [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]
[sig-cli] Kubectl client Kubectl cluster-info should check if Kubernetes control plane services is included in cluster-info  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]
[sig-scheduling] SchedulerPreemption [Serial] validates basic preemption works [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]
[sig-scheduling] SchedulerPreemption [Serial] validates lower priority pod preemption by critical pod [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]
[k8s.io] [sig-node] NoExecuteTaintManager Multiple Pods [Serial] evicts pods with minTolerationSeconds [Disruptive] [Conformance] [Suite:k8s]
[k8s.io] [sig-node] NoExecuteTaintManager Single Pod [Serial] removing taint cancels eviction [Disruptive] [Conformance] [Suite:k8s]
[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should mutate custom resource with pruning [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]
[sig-api-machinery] AdmissionWebhook [Privileged:ClusterAdmin] should mutate pod and apply defaults after mutation [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]
[sig-api-machinery] Aggregator Should be able to support the 1.17 Sample API Server using the current Aggregator [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]
[sig-apps] Daemon set [Serial] should rollback without unnecessary restarts [Conformance] [Skipped:SingleReplicaTopology] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]
[sig-network] Proxy version v1 A set of valid responses are returned for both pod and service ProxyWithPath [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]
EOF

./shellcheck.sh
./snc.sh

echo "### Extracting openshift-tests binary"
mkdir /tmp/os-test
export TESTS_IMAGE=$(oc --kubeconfig=crc-tmp-install-data/auth/kubeconfig adm release info -a "${HOME}"/pull-secret --image-for=tests)
oc image extract -a "${HOME}"/pull-secret "${TESTS_IMAGE}" --path=/usr/bin/openshift-tests:/tmp/os-test/.
chmod +x /tmp/os-test/openshift-tests
sudo mv /tmp/os-test/openshift-tests /usr/local/bin/

# Run createdisk script
export CRC_ZSTD_EXTRA_FLAGS="-10 --long"
./createdisk.sh crc-tmp-install-data

# Destroy the cluster
./openshift-baremetal-install destroy cluster --dir crc-tmp-install-data

# Unset the kubeconfig which is set by snc
unset KUBECONFIG

# Delete the dnsmasq config created by snc
# otherwise snc set the domain entry with 192.168.126.11
# and crc set it in another file 192.168.130.11 so
# better to remove the dnsmasq config after running snc
sudo rm -fr /etc/NetworkManager/dnsmasq.d/*
sudo systemctl reload NetworkManager

git clone https://github.com/code-ready/crc.git
pushd crc
make cross
sudo mv out/linux-amd64/crc /usr/local/bin/
popd

crc setup -b crc_libvirt_*.crcbundle
crc start --disk-size 80 -m 24000 -c 10 -p "${HOME}"/pull-secret -b crc_libvirt_*.crcbundle

mkdir -p /tmp/artifacts
export KUBECONFIG="${HOME}"/.crc/machines/crc/kubeconfig
openshift-tests run kubernetes/conformance --dry-run  | grep -F -v -f /tmp/ignoretests.txt  | openshift-tests run -o /tmp/artifacts/e2e.log --junit-dir /tmp/artifacts/junit -f -
rc=$?
echo "${rc}" > /tmp/test-return
set -e
echo "### Done! (${rc})"
