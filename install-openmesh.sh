#!/usr/bin/env bash

export HOME=/root
export KUBECONFIG=/etc/kubernetes/admin.conf
export PRODUCT_NAME=openmesh
export DOMAIN="tech.$PRODUCT_NAME.network"
export DOMAIN_WITH_DASHES="tech-$PRODUCT_NAME-network"

echo "uniq_id is injected in as $uniq_id"

export metal_network_cidr=$(jq -r .metal_network_cidr infra_config.json)
export first_assignable_host=$(python -c 'import ipaddress,os; print(ipaddress.IPv4Network(os.environ["metal_network_cidr"], strict=False).network_address + 1)')
export last_assignable_host=$(python -c 'import ipaddress,os; print(ipaddress.IPv4Network(os.environ["metal_network_cidr"], strict=False).broadcast_address - 1)')
echo "usable addresses are $first_assignable_host - $last_assignable_host"

echo "labelling the data plane"
kubectl label node $uniq_id-controller-primary plane=data

echo "creating namespaces"
cat << EOF > ns.yaml
apiVersion: v1
kind: Namespace
metadata:
  labels:
    kubernetes.io/metadata.name: $PRODUCT_NAME
  name: $PRODUCT_NAME

---

apiVersion: v1
kind: Namespace
metadata:
  labels:
    kubernetes.io/metadata.name: observability
  name: observability
EOF
kubectl apply -f ./ns.yaml

echo "creating storage classes"
cat << EOF > ./sc.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: default-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer

---

apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: kafka
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer

EOF
kubectl apply -f ./sc.yaml

echo "creating persistent volumes"
cat << EOF > ./pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: postgres-volume
spec:
  capacity:
    storage: 40Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: default-storage
  local:
    path: /data/postgres
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $uniq_id-controller-primary
  claimRef:
    name: data-postgres-postgresql-0
    namespace: $PRODUCT_NAME

---

apiVersion: v1
kind: PersistentVolume
metadata:
  name: prometheus-volume
spec:
  capacity:
    storage: 50Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: default-storage
  local:
    path: /data/prometheus
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $uniq_id-controller-primary
  claimRef:
    name: prometheus-server
    namespace: observability
EOF
kubectl apply -f ./pv.yaml

echo "creating secrets"
cat << EOF > secret.yaml
apiVersion: v1
data:
  .env: RVRIRVJFVU1fTk9ERV9IVFRQX1VSTD1odHRwczovL21haW5uZXQuaW5mdXJhLmlvL3YzLzc5YTEzNjRjN2ZhNjQ1NTE4ZTUzMmU0MjkwZDY0YWJlCkVUSEVSRVVNX05PREVfV1NfVVJMPXdzczovL21haW5uZXQuaW5mdXJhLmlvL3dzL3YzLzc5YTEzNjRjN2ZhNjQ1NTE4ZTUzMmU0MjkwZDY0YWJlCkVUSEVSRVVNX05PREVfU0VDUkVUPTVlNjYzYzUzOWE2MjRhZDVhOTYwY2Q4ZWE1MTZhZTcyCgpLQUZLQV9CT09UU1RSQVBfU0VSVkVSUz1rYWZrYS0wLWludGVybmFsLmNvbmZsdWVudDo5MDkyCgpTQ0hFTUFfUkVHSVNUUllfVVJMPWh0dHA6Ly9zY2hlbWFyZWdpc3RyeS0wLWludGVybmFsLmNvbmZsdWVudDo4MDgxCg==
kind: Secret
metadata:
  name: $PRODUCT_NAME-secrets
  namespace: $PRODUCT_NAME
type: Opaque
EOF
kubectl apply -f ./secret.yaml

pushd infra-helm-charts
git checkout feature/l3a-v3-install

pushd cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
                       --namespace cert-manager \
                       --create-namespace \
                       --version v1.12.1 \
                       --set installCRDs=true
sleep 10

cat << EOF > ./issuer.yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-staging
  namespace: $PRODUCT_NAME
spec:
  acme:
    # The ACME server URL
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: andrew.ong@openmesh.network
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: letsencrypt-staging
    # Enable the HTTP-01 challenge provider
    solvers:
    - http01:
        ingress:
          class:  nginx

---

apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-prod
  namespace: $PRODUCT_NAME
spec:
  acme:
    # The ACME server URL
    server: https://acme-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: andrew.ong@openmesh.network
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: letsencrypt-prod
    # Enable the HTTP-01 challenge provider
    solvers:
    - http01:
        ingress:
          class:  nginx

---

apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-staging
  namespace: observability
spec:
  acme:
    # The ACME server URL
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: andrew.ong@openmesh.network
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: letsencrypt-staging
    # Enable the HTTP-01 challenge provider
    solvers:
    - http01:
        ingress:
          class:  nginx

---

apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-prod
  namespace: observability
spec:
  acme:
    # The ACME server URL
    server: https://acme-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: andrew.ong@openmesh.network
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: letsencrypt-prod
    # Enable the HTTP-01 challenge provider
    solvers:
    - http01:
        ingress:
          class:  nginx
EOF
kubectl apply -f ./issuer.yaml

cat << EOF > ./cert.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: query-$uniq_id-$DOMAIN_WITH_DASHES-tls-static
  namespace: $PRODUCT_NAME
spec:
  secretName: query-$uniq_id-$DOMAIN_WITH_DASHES-tls-static
  issuerRef:
    name: letsencrypt-prod
  dnsNames:
  - 'query.$uniq_id.$DOMAIN'
EOF
kubectl apply -f ./cert.yaml
popd

pushd ingress-nginx
echo "ingctl time with $first_assignable_host"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install -n kube-system ingctl ingress-nginx/ingress-nginx \
                                      --version v4.7.0 \
                                      --set controller.service.loadBalancerIP=$first_assignable_host
sleep 10
popd

pushd postgresql
echo "$PRODUCT_NAME postgres time with $last_assignable_host"
helm repo add bitnami https://charts.bitnami.com/bitnami
helm dependency build
helm upgrade --install -n $PRODUCT_NAME postgres bitnami/postgresql \
                                 --version v12.5.9 \
                                 --set primary.service.loadBalancerIP=$last_assignable_host \
                                 -f baremetal.yaml

sleep 10
popd

pushd superset
export POSTGRES_PASSWORD=$(kubectl get secret --namespace $PRODUCT_NAME postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)
export SUPERSET_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
export SQLALCHEMY_URI="postgresql+psycopg2://postgres:$POSTGRES_PASSWORD@postgres-postgresql:5432/postgres"

sed "s,replace-with-real-sqlalchemy-uri,$SQLALCHEMY_URI," ./extraConfigs.template.yaml > ./extraConfigs.yaml

helm upgrade --install -n $PRODUCT_NAME superset . \
                                 --set "init.adminUser.password=$SUPERSET_PASSWORD" \
                                 --set "ingress.hosts[0]=query.$uniq_id.$DOMAIN" \
                                 --set "ingress.tls[0].secretName=query-$uniq_id-$DOMAIN_WITH_DASHES-tls-static" \
                                 --set "ingress.tls[0].hosts[0]=query.$uniq_id.$DOMAIN" \
                                 --set "supersetNode.connections.db_pass=$POSTGRES_PASSWORD" \
                                 -f baremetal.yaml \
                                 -f extraConfigs.yaml
sleep 10
popd

pushd prometheus
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm dependency build
helm upgrade --install -n observability prometheus prometheus-community/prometheus \
                                 --version 15.17.0 \
                                 -f baremetal.yaml

sleep 10
popd

pushd grafana
helm upgrade --install -n observability grafana . \
                                 --set 'dashboards.default.l3a-v3.file=""' \
                                 --set "ingress.hosts[0]=stats.$uniq_id.$DOMAIN" \
                                 --set "ingress.tls[0].secretName=stats-$uniq_id-$DOMAIN_WITH_DASHES-tls-static" \
                                 --set "ingress.tls[0].hosts[0]=stats.$uniq_id.$DOMAIN" \
                                 -f baremetal.yaml

sleep 30
admin_user_grafana=$(kubectl get secret -n observability grafana -o jsonpath="{.data.admin-user}" | base64 -d)
admin_password_grafana=$(kubectl get secret -n observability grafana -o jsonpath="{.data.admin-password}" | base64 -d)
prometheus_dashboard_uid_grafana=$(curl https://$admin_user_grafana:$admin_password_grafana@stats.$uniq_id.$DOMAIN/api/datasources/name/Prometheus | jq -r .uid)

sed "s/replace-with-real-uid/$prometheus_dashboard_uid_grafana/" ./dashboards/l3a-v3-dashboard.template.json > ./dashboards/l3a-v3-dashboard.json
sed "s/replace-with-real-uid/$prometheus_dashboard_uid_grafana/" ./dashboards/kafka-dashboard.template.json > ./dashboards/kafka-dashboard.json

helm upgrade --install -n observability grafana . \
                                 --set 'dashboards.default.l3a-v3.file=dashboards/l3a-v3-dashboard.json' \
                                 --set 'dashboards.default.kafka.file=dashboards/kafka-dashboard.json' \
                                 --set "ingress.hosts[0]=stats.$uniq_id.$DOMAIN" \
                                 --set "ingress.tls[0].secretName=stats-$uniq_id-$DOMAIN_WITH_DASHES-tls-static" \
                                 --set "ingress.tls[0].hosts[0]=stats.$uniq_id.$DOMAIN" \
                                 -f baremetal.yaml

sleep 10
popd

pushd confluent-for-kubernetes
kubectl create ns confluent

helm repo add confluentinc https://packages.confluent.io/helm
helm dependency build
helm upgrade --install -n confluent confluent-operator confluentinc/confluent-for-kubernetes \
                                 --version 0.771.13 \
                                 -f baremetal.yaml
sleep 10

echo "creating confluent zookeepers"
kubectl apply -f ./crs/zookeeper.yaml
sleep 10

echo "patching confluent zookeepers"
kubectl patch -n confluent pvc/data-zookeeper-0 -p '{"spec":{"volumeName":"data-zookeeper-volume"}}'
kubectl patch -n confluent pvc/txnlog-zookeeper-0 -p '{"spec":{"volumeName":"logs-zookeeper-volume"}}'
sleep 2

cat << EOF > ./zookeeper-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: data-zookeeper-volume
spec:
  capacity:
    storage: 10Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: kafka
  local:
    path: /data/zookeeper-data
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $uniq_id-controller-primary

---

apiVersion: v1
kind: PersistentVolume
metadata:
  name: logs-zookeeper-volume
spec:
  capacity:
    storage: 10Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: kafka
  local:
    path: /data/zookeeper-logs
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $uniq_id-controller-primary
EOF

echo "creating confluent zookeeper pv"
kubectl apply -f ./zookeeper-pv.yaml
sleep 10
echo "recycle confluent zookeeper pods"
kubectl delete -n confluent pod/zookeeper-0

echo "creating confluent brokers"
kubectl apply -f ./crs/broker.yaml
sleep 10
echo "patching confluent brokers"
kubectl patch -n confluent pvc/data0-kafka-0 -p '{"spec":{"volumeName":"data-broker0-volume"}}'
kubectl patch -n confluent pvc/data0-kafka-1 -p '{"spec":{"volumeName":"data-broker1-volume"}}'
kubectl patch -n confluent pvc/data0-kafka-2 -p '{"spec":{"volumeName":"data-broker2-volume"}}'
sleep 2

cat << EOF > ./broker-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: data-broker0-volume
spec:
  capacity:
    storage: 100Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: kafka
  local:
    path: /data/kafka
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $uniq_id-x86-blue-00

---

apiVersion: v1
kind: PersistentVolume
metadata:
  name: data-broker1-volume
spec:
  capacity:
    storage: 100Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: kafka
  local:
    path: /data/kafka
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $uniq_id-x86-blue-01

---

apiVersion: v1
kind: PersistentVolume
metadata:
  name: data-broker2-volume
spec:
  capacity:
    storage: 100Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: kafka
  local:
    path: /data/kafka
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $uniq_id-x86-blue-02
EOF

echo "creating confluent broker pv"
kubectl apply -f ./broker-pv.yaml
sleep 10
echo "recycling confluent brokers"
kubectl delete -n confluent pod/kafka-0 pod/kafka-1 pod/kafka-2
sleep 10
echo "enabling confluent crs"
kubectl apply -n confluent -f crs/kafka.yaml || kubectl apply -f crs/kafka.yaml
kubectl apply -n confluent -f crs/connect.yaml || kubectl apply -f crs/connect.yaml
kubectl apply -n confluent -f crs/schemaregistry.yaml || kubectl apply -f crs/schemaregistry.yaml
