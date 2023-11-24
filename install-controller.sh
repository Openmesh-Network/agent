#!/bin/bash

bootstrap () {
  export HOME=/root
  export PRODUCT_NAME=openmesh
  export BUILD_DIR=$HOME/$PRODUCT_NAME-install
  export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"

  mkdir -p $HOME/kube
  mkdir -p \
    /data/kafka \
    /data/postgres \
    /data/prometheus \
    /data/superset \
    /data/zookeeper-data \
    /data/zookeeper-logs
}

install_utils () {
  apt-get update && apt-get install -y inotify-tools jq python3 wcstools
  add-apt-repository ppa:rmescandon/yq -y && apt-get update
  apt-get install -y yq

  if [[ ! $(command -v kubectl-krew) ]]; then install_kubectl_krew; fi
  if [[ ! $(command -v kubectl-slice) ]]; then install_kubectl_slice; fi
}

install_kubectl_krew () {
  set -x; local tmpdir="$(mktemp -d)" && pushd "$tmpdir" &&
  OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
  ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
  KREW="krew-${OS}_${ARCH}" &&
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
  tar zxvf "${KREW}.tar.gz" &&
  ./"${KREW}" install krew

  if [[ $(command -v kubectl-krew) ]]; then popd; rm -rf $tmpdir; fi
}

install_kubectl_slice () {
  kubectl-krew install slice
}

install_manifest () {
  apt-get update && apt-get install -y jq wcstools yq
  local url=$1
  local fp
  pushd "$(mktemp -d)" && \
    mkdir original && \
    mkdir final
  curl -L $url > allinone.yaml
  kubectl-slice -f allinone.yaml -o original
  kubectl-slice -f allinone.yaml -o final
  for fp in $(find original -name deployment-*.yaml); do
    local file=$(filename $fp)
    rm -rf final/$file

    local tempfile=$(mktemp)
    yq r -j $fp > $tempfile
    jq '.spec.template.spec.tolerations += [{"key":"node-role.kubernetes.io/control-plane", "operator":"Equal", "effect":"NoSchedule"}]' $tempfile > final/$file.json
    rm -rf $tempfile
  done
  kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f final
  popd
}

load_config () {
  while [ ! -f "$HOME/infra_config.json" ]
  do
    inotifywait -qqt 2 -e create -e moved_to "$(dirname $HOME/infra_config.json)"
    echo "infra_config.json file not found, cowardly looping"
  done
  while [ ! -f "$HOME/workloads.json" ]
  do
    inotifywait -qqt 2 -e create -e moved_to "$(dirname $HOME/workloads.json)"
    echo "workloads.json file not found, cowardly looping"
  done

  readonly INFRA_CONFIG=$(< "$HOME/infra_config.json")
  readonly WORKLOADS=$(< "$HOME/workloads.json")
}

extract_settings () {
  export ccm_enabled=$(jq -r .ccm_enabled <<< $INFRA_CONFIG)
  export cni_cidr=$(jq -r .cni_cidr <<< $WORKLOADS)
  export configure_ingress=$(jq -r .configure_ingress <<< $INFRA_CONFIG)
  export control_plane_node_count=$(jq -r .control_plane_node_count <<< $INFRA_CONFIG)
  export count=$(jq -r .count <<< $INFRA_CONFIG)
  export count_gpu=$(jq -r .count_gpu <<< $INFRA_CONFIG)
  export gateway_ip=$(curl https://metadata.platformequinix.com/metadata | jq -r '.network.addresses[] | select(.public == false) | .gateway')

  export kube_token=$(jq -r .kube_token <<< $INFRA_CONFIG)
  export kube_version=$(jq -r .kube_version <<< $INFRA_CONFIG)
  export loadbalancer_type=$(jq -r .loadbalancer_type <<< $INFRA_CONFIG)
  export metallb_configmap=$(jq -r .metallb_configmap <<< $INFRA_CONFIG)
  export metallb_namespace=$(jq -r .metallb_namespace <<< $INFRA_CONFIG)
  export metallb_network_cidr=$(jq -r .metallb_network_cidr <<< $INFRA_CONFIG)
  export metallb_release=$(jq -r .metallb_release <<< $WORKLOADS)
  export private_management_ip=$(curl -s http://metadata.platformequinix.com/metadata | jq -r '.network.addresses[] | select(.public == false) | select(.management == true) | select(.address_family == 4) | .address')
  export public_management_ip=$(curl -s http://metadata.platformequinix.com/metadata | jq -r '.network.addresses[] | select(.public == true) | select(.management == true) | select(.address_family == 4) | .address')

  export secrets_encryption=$(jq -r .secrets_encryption <<< $INFRA_CONFIG)
  export shortlived_kube_token=$(jq -r .shortlived_kube_token <<< $INFRA_CONFIG)
  export storage=$(jq -r .storage <<< $INFRA_CONFIG)

  export equinix_api_key=$(jq -r .equinix_api_key <<< $INFRA_CONFIG)
  export equinix_project_id=$(jq -r .equinix_project_id <<< $INFRA_CONFIG)
  export equinix_metro=$(jq -r .equinix_metro <<< $INFRA_CONFIG)
  export equinix_facility=$(jq -r .equinix_facility <<< $INFRA_CONFIG)
  export loadbalancer=$(jq -r .loadbalancer <<< $INFRA_CONFIG)
}

install_containerd () {
  cat <<EOF > /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

  echo "Installing Containerd..."
  modprobe overlay
  modprobe br_netfilter
  apt-get update && apt-get install -y ca-certificates socat ebtables apt-transport-https cloud-utils prips containerd jq python3
}

enable_containerd () {
  systemctl daemon-reload
  systemctl enable containerd
  systemctl start containerd
}

install_kube_tools () {
  echo $kube_token
  echo "Installing kubeadm tools for version $kube_version"
  sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab
  swapoff -a
  apt-get update && apt-get install -y apt-transport-https
  curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
  echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list && apt-get update
  apt-get update && apt-get install -y kubelet=$kube_version kubeadm=$kube_version kubectl=$kube_version
}

init_cluster_config () {
  echo $cni_cidr
  cat << EOF > /etc/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
bootstrapTokens:
- token: "$kube_token"
  description: "default kubeadm bootstrap token"
  ttl: "0"
- token: "$shortlived_kube_token"
  description: "short lived kubeadm bootstrap token"
  ttl: "72h"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: stable
controlPlaneEndpoint: "$private_management_ip:6443"
networking:
  podSubnet: "$cni_cidr"
certificatesDir: /etc/kubernetes/pki
EOF

  kubeadm init --config=/etc/kubeadm-config.yaml
  kubeadm init phase upload-certs --upload-certs
}

init_cluster () {
  echo $kube_token
  echo $shortlived_kube_token
  echo $cni_cidr
  echo "Initializing cluster..."
  cat <<EOF > /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

  sysctl --system
  cat << EOF > /etc/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
bootstrapTokens:
- token: "$kube_token"
  description: "default kubeadm bootstrap token"
  ttl: "0"
- token: "$shortlived_kube_token"
  description: "short lived kubeadm bootstrap token"
  ttl: "72h"
localAPIEndpoint:
  advertiseAddress: $private_management_ip
  bindPort: 6443
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: stable
controlPlaneEndpoint: "$private_management_ip:6443"
apiServer:
  certSANs:
    - "$private_management_ip"
    - "$public_management_ip"
networking:
  podSubnet: "$cni_cidr"
certificatesDir: /etc/kubernetes/pki
EOF

  echo kubeadm init --config=/etc/kubeadm-config.yaml
  kubeadm init --config=/etc/kubeadm-config.yaml
}

configure_network () {
  for w in $(jq -r .cni_workloads[] < $HOME/workloads.json); do
    echo $w
    # we use `kubectl create` command instead of `apply` because it fails on kubernetes version <1.22
    # err: The CustomResourceDefinition "installations.operator.tigera.io" is invalid: metadata.annotations: Too long: must have at most 262144 bytes
    kubectl --kubeconfig=/etc/kubernetes/admin.conf create -f $w
    sleep 30
  done
}

gpu_config () {
  export count_gpu=$(cat $HOME/infra_config.json | jq -r .count_gpu) && \
  if [ "$count_gpu" = "0" ]; then
	echo "No GPU nodes to prepare for presently...moving on..."
  else
	kubectl --kubeconfig=/etc/kubernetes/admin.conf create -f $(cat $HOME/workloads.json | jq .nvidia_gpu)
  fi
}

install_metallb () {
  echo $metallb_namespace
  echo $metallb_configmap
  echo $metallb_network_cidr
  echo $metallb_release
  echo "Applying Metallb manifests..."
  install_manifest "$metallb_release" && sleep 15
  install_manifest "$metallb_release" && sleep 30

  echo "Configuring Metallb for $metallb_network_cidr..."
  cat << EOF > $HOME/kube/metallb.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: production
  namespace: $metallb_namespace
spec:
  addresses:
  - $metallb_network_cidr
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: empty
  namespace: $metallb_namespace
EOF
    kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f $HOME/kube/metallb.yaml || kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f $HOME/kube/metallb.yaml
    sleep 15
    kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f $HOME/kube/metallb.yaml || kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f $HOME/kube/metallb.yaml
}

kube_vip () {
  IMAGE=ghcr.io/kube-vip/kube-vip:v0.4.0
  kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f https://kube-vip.io/manifests/rbac.yaml
  ctr i pull $IMAGE
  ctr run --rm --net-host $IMAGE vip-$RANDOM /kube-vip manifest daemonset \
  --interface lo \
  --services \
  --bgp \
  --annotations metal.equinix.com \
  --inCluster | kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f -
}

ceph_pre_check () {
  apt install -y lvm2 ; \
  modprobe rbd
}

ceph_rook_basic () {
  export count=$(cat $HOME/infra_config.json | jq -r .count) && \
  cd $HOME/kube ; \
  mkdir ceph ;\
  echo "Pulled Manifest for Ceph-Rook..." && \
  kubectl --kubeconfig=/etc/kubernetes/admin.conf create -f $(cat $HOME/workloads.json | jq .ceph_common) ; \
  sleep 30 ; \
  echo "Applying Ceph Operator..." ; \
  kubectl --kubeconfig=/etc/kubernetes/admin.conf create -f $(cat $HOME/workloads.json | jq .ceph_operator) ; \
  sleep 30 ; \
  echo "Creating Ceph Cluster..." ; \
  if [ "$count" -gt 3 ]; then
	  echo "Node count less than 3, creating minimal cluster" ; \
  	kubectl --kubeconfig=/etc/kubernetes/admin.conf create -f $(cat $HOME/workloads.json | jq .ceph_cluster_minimal)
  else
  	kubectl --kubeconfig=/etc/kubernetes/admin.conf create -f $(cat $HOME/workloads.json | jq .ceph_cluster)
  fi
}

ceph_storage_class () {
  cat << EOF > $HOME/kube/ceph-sc.yaml
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: replicapool
  namespace: rook-ceph
spec:
  failureDomain: host
  replicated:
    size: 3
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
   name: rook-ceph-block
provisioner: ceph.rook.io/block
parameters:
  blockPool: replicapool
  # The value of "clusterNamespace" MUST be the same as the one in which your rook cluster exist
  clusterNamespace: rook-ceph
  fstype: xfs
# Optional, default reclaimPolicy is "Delete". Other options are: "Retain", "Recycle" as documented in https://kubernetes.io/docs/concepts/storage/storage-classes/
reclaimPolicy: Retain
EOF
}

gen_encryption_config () {
  echo "Generating EncryptionConfig for cluster..." && \
  export BASE64_STRING=$(head -c 32 /dev/urandom | base64) && \
  cat << EOF > /etc/kubernetes/secrets.conf
apiVersion: v1
kind: EncryptionConfig
resources:
- providers:
  - aescbc:
      keys:
      - name: key1
        secret: $BASE64_STRING
  resources:
  - secrets
EOF
}

modify_encryption_config () {
#Validate Encrypted Secret:
# ETCDCTL_API=3 etcdctl --cert="/etc/kubernetes/pki/etcd/server.crt" --key="/etc/kubernetes/pki/etcd/server.key" --cacert="/etc/kubernetes/pki/etcd/ca.crt" get /registry/secrets/default/personal-secret | hexdump -C
  echo "Updating Kube APIServer Configuration for At-Rest Secret Encryption..." && \
  sed -i 's|- kube-apiserver|- kube-apiserver\n    - --experimental-encryption-provider-config=/etc/kubernetes/secrets.conf|g' /etc/kubernetes/manifests/kube-apiserver.yaml && \
  sed -i 's|  volumes:|  volumes:\n  - hostPath:\n      path: /etc/kubernetes/secrets.conf\n      type: FileOrCreate\n    name: secretconfig|g' /etc/kubernetes/manifests/kube-apiserver.yaml  && \
  sed -i 's|    volumeMounts:|    volumeMounts:\n    - mountPath: /etc/kubernetes/secrets.conf\n      name: secretconfig\n      readOnly: true|g' /etc/kubernetes/manifests/kube-apiserver.yaml
}

install_extra () {
  for w in $(jq -r .extra[] < $HOME/workloads.json); do
    echo $w
    kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f $w
  done
}

bgp_routes () {
  echo $gateway_ip
  # TODO use metadata peer ips
  ip route add 169.254.255.1 via $gateway_ip
  ip route add 169.254.255.2 via $gateway_ip
  sed -i.bak -E "/^\s+post-down route del -net 10\.0\.0\.0.* gw .*$/a \ \ \ \ up ip route add 169.254.255.1 via $gateway_ip || true\n    up ip route add 169.254.255.2 via $gateway_ip || true\n    down ip route del 169.254.255.1 || true\n    down ip route del 169.254.255.2 || true" /etc/network/interfaces
}

install_ccm () {
  echo $equinix_api_key
  echo $equinix_project_id
  echo $equinix_metro
  echo $equinix_facility
  echo $loadbalancer
  local release=$(jq -r .ccm_version <<< $INFRA_CONFIG)

  cat << EOF > $HOME/kube/equinix-ccm-config.yaml
apiVersion: v1
kind: Secret
metadata:
  name: metal-cloud-config
  namespace: kube-system
stringData:
  cloud-sa.json: |
    {
      "apiKey": "$equinix_api_key",
      "projectID": "$equinix_project_id",
      "metro": "$equinix_metro",
      "loadbalancer": "$loadbalancer"
    }
EOF

kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f $HOME/kube/equinix-ccm-config.yaml

install_manifest "https://github.com/equinix/cloud-provider-equinix-metal/releases/download/$release/deployment.yaml"
}

main () {
  bootstrap
  install_utils
  load_config
  extract_settings
  install_containerd
  enable_containerd
  install_kube_tools
  if [ "$ccm_enabled" = "true" ]; then echo KUBELET_EXTRA_ARGS=\"--cloud-provider=external\" > /etc/default/kubelet; fi
  if [ "$control_plane_node_count" = "0" ]; then
    echo "No control plane nodes provisioned, initializing single master..."
    init_cluster
  else
    echo "Writing config for control plane nodes..."
    init_cluster_config
  fi
  echo "sleeping for 30s..." && sleep 30

  bgp_routes
  configure_network
  if [ "$ccm_enabled" = "true" ]; then install_ccm; sleep 30; fi
  if [ "$loadbalancer_type" = "metallb" ]; then install_metallb; sleep 30; install_metallb; fi
  if [ "$loadbalancer_type" = "kube-vip" ]; then kube_vip; sleep 30; kube_vip; fi

  install_extra
}

main
