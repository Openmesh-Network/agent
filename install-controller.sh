#!/bin/bash

export HOME=/root
mkdir $HOME/kube

load_infra_config () {
  INFRA_CONFIG=$(cat "$HOME/infra_config.json")
}

load_workloads () {
  WORKLOADS=$(cat $HOME/workloads.json)
}

install_containerd () {
cat <<EOF > /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
 modprobe overlay
 modprobe br_netfilter
 echo "Installing Containerd..."
 apt-get update
 apt-get install -y ca-certificates socat ebtables apt-transport-https cloud-utils prips containerd jq python3 ipcalc
}

enable_containerd () {
 systemctl daemon-reload
 systemctl enable containerd
 systemctl start containerd
}

install_kube_tools () {
 export kube_version=$(cat $HOME/infra_config.json | jq -r .kube_version) && \
 echo "Installing Kubeadm tools..." ;
 sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab
 swapoff -a
 apt-get update && apt-get install -y apt-transport-https
 curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
 echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
 apt-get update
 apt-get install -y kubelet=$kube_version kubeadm=$kube_version kubectl=$kube_version
}

init_cluster_config () {
    export kube_token=$(cat $HOME/infra_config.json | jq -r .kube_token) && \
    export shortlived_kube_token=$(cat $HOME/infra_config.json | jq -r .shortlived_kube_token) && \
    export CNI_CIDR=$(cat $HOME/workloads.json | jq -r .cni_cidr) && \
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
controlPlaneEndpoint: "$(curl -s http://metadata.platformequinix.com/metadata | jq -r '.network.addresses[] | select(.public == false) | select(.management == true) | select(.address_family == 4) | .address'):6443"
networking:
  podSubnet: "$CNI_CIDR"
certificatesDir: /etc/kubernetes/pki
EOF
    kubeadm init --config=/etc/kubeadm-config.yaml ; \
    kubeadm init phase upload-certs --upload-certs
}

init_cluster () {
    export kube_token=$(cat $HOME/infra_config.json | jq -r .kube_token) && \
    export shortlived_kube_token=$(cat $HOME/infra_config.json | jq -r .shortlived_kube_token) && \
    export CNI_CIDR=$(cat $HOME/workloads.json | jq -r .cni_cidr) && \
    echo "Initializing cluster..." && \
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
  advertiseAddress: $(curl -s http://metadata.platformequinix.com/metadata | jq -r '.network.addresses[] | select(.public == false) | select(.management == true) | select(.address_family == 4) | .address')
  bindPort: 6443
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: stable
controlPlaneEndpoint: "$(curl -s http://metadata.platformequinix.com/metadata | jq -r '.network.addresses[] | select(.public == false) | select(.management == true) | select(.address_family == 4) | .address'):6443"
apiServer:
  certSANs:
    - "$(curl -s http://metadata.platformequinix.com/metadata | jq -r '.network.addresses[] | select(.public == false) | select(.management == true) | select(.address_family == 4) | .address')"
    - "$(curl -s http://metadata.platformequinix.com/metadata | jq -r '.network.addresses[] | select(.public == true) | select(.management == true) | select(.address_family == 4) | .address')"
networking:
  podSubnet: "$CNI_CIDR"
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

metal_lb () {
  export metal_namespace=$(cat $HOME/infra_config.json | jq -r .metal_namespace) && \
  export metal_configmap=$(cat $HOME/infra_config.json | jq -r .metal_configmap) && \
  export metal_network_cidr=$(cat $HOME/infra_config.json | jq -r .metal_network_cidr) && \
  echo "Applying MetalLB manifests..." && \
    cd $HOME/kube && \
    kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f $(cat $HOME/workloads.json | jq .metallb_release)
    sleep 15
    kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f $(cat $HOME/workloads.json | jq .metallb_release) 
  sleep 30

  echo "Configuring MetalLB for $metal_network_cidr..." && \
    cd $HOME/kube ; \
    cat << EOF > metal_lb.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: production
  namespace: $metal_namespace
spec:
  addresses:
  - $metal_network_cidr

---

apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: empty
  namespace: $metal_namespace
EOF
    kubectl --kubeconfig=/etc/kubernetes/admin.conf create -f metal_lb.yaml
    sleep 15
    kubectl --kubeconfig=/etc/kubernetes/admin.conf create -f metal_lb.yaml
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

apply_extra () {
  for w in $(jq -r .extra[] < $HOME/workloads.json); do
    echo $w
    kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f $w
  done
}

bgp_routes () {
    GATEWAY_IP=$(curl https://metadata.platformequinix.com/metadata | jq -r ".network.addresses[] | select(.public == false) | .gateway")
    # TODO use metadata peer ips
    ip route add 169.254.255.1 via $GATEWAY_IP
    ip route add 169.254.255.2 via $GATEWAY_IP
    sed -i.bak -E "/^\s+post-down route del -net 10\.0\.0\.0.* gw .*$/a \ \ \ \ up ip route add 169.254.255.1 via $GATEWAY_IP || true\n    up ip route add 169.254.255.2 via $GATEWAY_IP || true\n    down ip route del 169.254.255.1 || true\n    down ip route del 169.254.255.2 || true" /etc/network/interfaces
}

install_ccm () {
  export equinix_api_key=$(cat $HOME/infra_config.json | jq -r .equinix_api_key) && \
  export equinix_project_id=$(cat $HOME/infra_config.json | jq -r .equinix_project_id) && \
  export equinix_metro=$(cat $HOME/infra_config.json | jq -r .equinix_metro) && \
  export equinix_facility=$(cat $HOME/infra_config.json | jq -r .equinix_facility) && \
  export loadbalancer=$(cat $HOME/infra_config.json | jq -r .loadbalancer) && \
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
RELEASE=$(cat $HOME/infra_config.json | jq -r .ccm_version)
kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f https://github.com/equinix/cloud-provider-equinix-metal/releases/download/$RELEASE/deployment.yaml
}

install_containerd && \
enable_containerd && \
load_infra_config && \
load_workloads && \
install_kube_tools && \
sleep 30 && \

export ccm_enabled=$(cat $HOME/infra_config.json | jq -r .ccm_enabled)
export control_plane_node_count=$(cat $HOME/infra_config.json | jq -r .control_plane_node_count)
export loadbalancer_type=$(cat $HOME/infra_config.json | jq -r .loadbalancer_type)
export count_gpu=$(cat $HOME/infra_config.json | jq -r .count_gpu)
export storage=$(cat $HOME/infra_config.json | jq -r .storage)
export configure_ingress=$(cat $HOME/infra_config.json | jq -r .configure_ingress)
export secrets_encryption=$(cat $HOME/infra_config.json | jq -r .secrets_encryption)

if [ "$ccm_enabled" = "true" ]; then
  echo KUBELET_EXTRA_ARGS=\"--cloud-provider=external\" > /etc/default/kubelet
fi
if [ "$control_plane_node_count" = "0" ]; then
  echo "No control plane nodes provisioned, initializing single master..." ; \
  init_cluster
else
  echo "Writing config for control plane nodes..." ; \
  init_cluster_config
fi

sleep 180 && \
bgp_routes && \
configure_network
if [ "$ccm_enabled" = "true" ]; then
  install_ccm
  sleep 30 # The CCM will probably take a while to reconcile
  if [ "$loadbalancer_type" = "metallb" ]; then
    metal_lb
  fi
  if [ "$loadbalancer_type" = "kube-vip" ]; then
    kube_vip
  fi
fi
if [ "$count_gpu" = "0" ]; then
  echo "Skipping GPU enable..."
else
  gpu_enable
fi
if [ "$storage" = "openebs" ]; then
   kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f $(cat $HOME/workloads.json | jq .open_ebs_operator)
elif [ "$storage" = "ceph" ]; then
  ceph_pre_check && \
  echo "Configuring Ceph Operator" ; \
  ceph_rook_basic && \
  ceph_storage_class ; \
  kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f $HOME/kube/ceph-sc.yaml
else
  echo "Skipping storage provider setup..."
fi
if [ "$configure_ingress" = "yes" ]; then
  echo "Making controller schedulable..." ; \
  kubectl --kubeconfig=/etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/master- && \
  echo "Configuring Ingress Controller..." ; \
  kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f $(cat $HOME/workloads.json | jq .ingress_controller )
else
  echo "Not configuring ingress controller..."
fi
if [ "$secrets_encryption" = "yes" ]; then
  echo "Secrets Encrypted selected...configuring..." && \
  gen_encryption_config && \
  sleep 60 && \
  modify_encryption_config
else
  echo "Secrets Encryption not selected...finishing..."
fi
apply_extra || echo "Extra workloads not applied. Finished."
