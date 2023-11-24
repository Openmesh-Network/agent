#!/usr/bin/env bash

bootstrap () {
  export PRODUCT_NAME=openmesh
  export DOMAIN="tech.$PRODUCT_NAME.network"
  export DOMAIN_WITH_DASHES=$(sed 's/\./-/g' <<< $DOMAIN)
}

load_config () {
  while [ ! -f infra_config.json ]
  do
    inotifywait -qqt 2 -e create -e moved_to "$(dirname infra_config.json)"
    echo "infra_config.json file not found, cowardly looping"
  done
  readonly INFRA_CONFIG=$(< infra_config.json)
}

extract_settings () {
  export metallb_network_cidr=$(jq -r .metallb_network_cidr <<< $INFRA_CONFIG)
  export single_xnode=$(jq -r .single_xnode <<< $INFRA_CONFIG)
  if [[ $single_xnode == true ]]; then export nodes=0; else export nodes=$(jq -r .count <<< $INFRA_CONFIG); fi
  export grafana=$(jq -r .grafana <<< $INFRA_CONFIG)

  export first_assignable_host=$(python -c 'import ipaddress,os; print(ipaddress.IPv4Network(os.environ["metallb_network_cidr"], strict=False).network_address + 1)')
  export last_assignable_host=$(python -c 'import ipaddress,os; print(ipaddress.IPv4Network(os.environ["metallb_network_cidr"], strict=False).broadcast_address - 1)')
  echo "usable addresses are $first_assignable_host - $last_assignable_host"
}

check_api () {
  local attempts=0
  local response_code=0
  local url=$1
  local service=$2

  until [[ $response_code -eq 200 ]] || [[ $attempts -gt 60 ]]; do
    response_code=$(curl -sL -w "%{http_code}" -o /dev/null "$url")
    attempts=$((attempts + 1))
    echo "response code is $response_code, attempt $attempts for $service" && sleep 10
  done
}

add_custom_label () {
  echo "labelling the data plane"
  kubectl label node $uniq_id-controller-primary plane=data
}

create_namespace () {
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
  echo "creating namespaces"
  kubectl apply -f ./ns.yaml
}

create_sc () {
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
  echo "creating storage classes"
  kubectl apply -f ./sc.yaml
}

create_pv () {
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
  echo "creating persistent volumes"
  kubectl apply -f ./pv.yaml
}

create_secret () {
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
  echo "creating secrets"
  kubectl apply -f ./secret.yaml
}

install_cert_manager () {
  pushd cert-manager
  helm repo add jetstack https://charts.jetstack.io
  helm repo update
  helm upgrade --install cert-manager jetstack/cert-manager \
                         --namespace cert-manager \
                         --create-namespace \
                         --version v1.12.1 \
                         --set installCRDs=true \
                         --set tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set tolerations[0].operator=Exists \
                         --set tolerations[0].effect=NoSchedule \
                         --set webhook.tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set webhhok.tolerations[0].operator=Exists \
                         --set webhhok.tolerations[0].effect=NoSchedule \
                         --set cainjector.tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set cainjector.tolerations[0].operator=Exists \
                         --set cainjector.tolerations[0].effect=NoSchedule \
                         --set startupapicheck.tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set startupapicheck.tolerations[0].operator=Exists \
                         --set startupapicheck.tolerations[0].effect=NoSchedule
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
          podTemplate:
            spec:
              tolerations:
              - effect: NoSchedule
                key: node-role.kubernetes.io/control-plane
                operator: Equal
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
          podTemplate:
            spec:
              tolerations:
              - effect: NoSchedule
                key: node-role.kubernetes.io/control-plane
                operator: Equal
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
          podTemplate:
            spec:
              tolerations:
              - effect: NoSchedule
                key: node-role.kubernetes.io/control-plane
                operator: Equal
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
          podTemplate:
            spec:
              tolerations:
              - effect: NoSchedule
                key: node-role.kubernetes.io/control-plane
                operator: Equal
EOF
  kubectl apply -f ./issuer.yaml
  sleep 10 && popd
}

install_ingress_nginx () {
  pushd ingress-nginx
  echo "ingctl time with $first_assignable_host"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo update
  helm upgrade --install ingctl ingress-nginx/ingress-nginx \
                         --namespace kube-system \
                         --version v4.7.0 \
                         --set controller.service.loadBalancerIP=$first_assignable_host \
                         --set controller.tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set controller.tolerations[0].operator=Exists \
                         --set controller.tolerations[0].effect=NoSchedule \
                         --set controller.admissionWebhooks.patch.tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set controller.admissionWebhooks.patch.tolerations[0].operator=Exists \
                         --set controller.admissionWebhooks.patch.tolerations[0].effect=NoSchedule \
                         --set defaultBackend.tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set defaultBackend.tolerations[0].operator=Exists \
                         --set defaultBackend.tolerations[0].effect=NoSchedule
  sleep 10 && popd
}

install_postgres () {
  pushd postgresql
  echo "$PRODUCT_NAME postgres time with $last_assignable_host"
  helm repo add bitnami https://charts.bitnami.com/bitnami
  helm dependency build
  helm upgrade --install postgres bitnami/postgresql \
                         --namespace $PRODUCT_NAME \
                         --version v12.5.9 \
                         --set primary.service.loadBalancerIP=$last_assignable_host \
                         -f baremetal.yaml
  sleep 10 && popd
}

install_superset () {
  pushd superset
  export POSTGRES_PASSWORD=$(kubectl get secret --namespace $PRODUCT_NAME postgres-postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)
  export SUPERSET_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
  export SQLALCHEMY_URI="postgresql+psycopg2://postgres:$POSTGRES_PASSWORD@postgres-postgresql:5432/postgres"
  
  sed "s,replace-with-real-sqlalchemy-uri,$SQLALCHEMY_URI," ./extraConfigs.template.yaml > ./extraConfigs.yaml
  
  helm upgrade --install superset . \
                         --namespace $PRODUCT_NAME \
                         --set "init.adminUser.password=$SUPERSET_PASSWORD" \
                         --set "ingress.hosts[0]=query.$uniq_id.$DOMAIN" \
                         --set "ingress.tls[0].secretName=query-$uniq_id-$DOMAIN_WITH_DASHES-tls-static" \
                         --set "ingress.tls[0].hosts[0]=query.$uniq_id.$DOMAIN" \
                         --set "supersetNode.connections.db_pass=$POSTGRES_PASSWORD" \
                         --set tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set tolerations[0].operator=Exists \
                         --set tolerations[0].effect=NoSchedule \
                         --set redis.master.tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set redis.master.tolerations[0].operator=Exists \
                         --set redis.master.tolerations[0].effect=NoSchedule \
                         -f baremetal.yaml \
                         -f extraConfigs.yaml
  sleep 10 && popd
}

install_prometheus () {
  pushd prometheus
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm dependency build
  helm upgrade --install prometheus prometheus-community/prometheus \
                         --namespace observability \
                         --version 15.17.0 \
                         --set kube-state-metrics.tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set kube-state-metrics.tolerations[0].operator=Exists \
                         --set kube-state-metrics.tolerations[0].effect=NoSchedule \
                         --set nodeExporter.tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set nodeExporter.tolerations[0].operator=Exists \
                         --set nodeExporter.tolerations[0].effect=NoSchedule \
                         --set pushgateway.tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set pushgateway.tolerations[0].operator=Exists \
                         --set pushgateway.tolerations[0].effect=NoSchedule \
                         -f baremetal.yaml

  sleep 10 && popd
}

install_grafana () {
  pushd grafana
  helm upgrade --install grafana . \
                         --namespace observability \
                         --set 'dashboards.default.openmesh.file=""' \
                         --set 'dashboards.default.kafka.file=""' \
                         --set "grafana\.ini.server.root_url=https://stats.$uniq_id.$DOMAIN" \
                         --set "ingress.hosts[0]=stats.$uniq_id.$DOMAIN" \
                         --set "ingress.tls[0].secretName=stats-$uniq_id-$DOMAIN_WITH_DASHES-tls-static" \
                         --set "ingress.tls[0].hosts[0]=stats.$uniq_id.$DOMAIN" \
                         --set tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set tolerations[0].operator=Exists \
                         --set tolerations[0].effect=NoSchedule \
                         --set imageRenderer.tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set imageRenderer.tolerations[0].operator=Exists \
                         --set imageRenderer.tolerations[0].effect=NoSchedule \
                         -f baremetal.yaml
  
  sleep 30
  admin_user_grafana=$(kubectl get secret -n observability grafana -o jsonpath="{.data.admin-user}" | base64 -d)
  admin_password_grafana=$(kubectl get secret -n observability grafana -o jsonpath="{.data.admin-password}" | base64 -d)
  check_api "https://$admin_user_grafana:$admin_password_grafana@stats.$uniq_id.$DOMAIN/api/datasources/name/Prometheus" grafana
  prometheus_dashboard_uid_grafana=$(curl -L https://$admin_user_grafana:$admin_password_grafana@stats.$uniq_id.$DOMAIN/api/datasources/name/Prometheus | jq -r .uid)
  
  sed "s/replace-with-real-uid/$prometheus_dashboard_uid_grafana/" ./dashboards/openmesh-dashboard.template.json > ./dashboards/openmesh-dashboard.json
  sed "s/replace-with-real-uid/$prometheus_dashboard_uid_grafana/" ./dashboards/kafka-dashboard.template.json > ./dashboards/kafka-dashboard.json

  helm upgrade --install grafana . \
                         --namespace observability \
                         --set 'dashboards.default.openmesh.file=dashboards/openmesh-dashboard.json' \
                         --set 'dashboards.default.kafka.file=dashboards/kafka-dashboard.json' \
                         --set "grafana\.ini.server.root_url=https://stats.$uniq_id.$DOMAIN" \
                         --set "ingress.hosts[0]=stats.$uniq_id.$DOMAIN" \
                         --set "ingress.tls[0].secretName=stats-$uniq_id-$DOMAIN_WITH_DASHES-tls-static" \
                         --set "ingress.tls[0].hosts[0]=stats.$uniq_id.$DOMAIN" \
                         --set tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set tolerations[0].operator=Exists \
                         --set tolerations[0].effect=NoSchedule \
                         --set imageRenderer.tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set imageRenderer.tolerations[0].operator=Exists \
                         --set imageRenderer.tolerations[0].effect=NoSchedule \
                         -f baremetal.yaml

  check_api "https://$admin_user_grafana:$admin_password_grafana@stats.$uniq_id.$DOMAIN/api/dashboards/uid/openmesh" grafana

  while read dashboard; do
    local name=$(jq -r .name <<< $dashboard)
    local access_token=$(jq -r .token <<< $dashboard)

    local json_payload=$(jq --arg accessToken "$access_token" --arg uid "$name" '. + { "accessToken": $accessToken, "uid": $uid }' <<< \
    '{"timeSelectionEnabled": false, "isEnabled": true, "annotationsEnabled": false, "share": "public"}')

    curl -XPOST \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json' \
      -d "$json_payload" \
      https://$admin_user_grafana:$admin_password_grafana@stats.$uniq_id.$DOMAIN/api/dashboards/uid/$name/public-dashboards
  done <<< $(jq -c .[] <<< $grafana)

  sleep 10 && popd
}

install_cfk () {
  pushd confluent-for-kubernetes
  kubectl create ns confluent
  
  helm repo add confluentinc https://packages.confluent.io/helm
  helm dependency build
  helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
                         --namespace confluent \
                         --version 0.771.13 \
                         --set tolerations[0].key=node-role.kubernetes.io/control-plane \
                         --set tolerations[0].operator=Exists \
                         --set tolerations[0].effect=NoSchedule \
                         -f baremetal.yaml
  sleep 10
}

configure_broker_pv () {
  local num_of_nodes=$1
  > ./broker-pv.yaml
  if [[ $num_of_nodes -eq 0 ]]; then
    cat << EOF > ./broker-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: data-broker0-volume
spec:
  capacity:
    storage: 400Gi
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
          - $uniq_id-controller-primary
EOF
  else
    local n
    for n in $(seq 0 $((num_of_nodes - 1))); do
      cat << EOF >> ./broker-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: data-broker$n-volume
spec:
  capacity:
    storage: 400Gi
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
          - $uniq_id-x86-blue-0$n
---
EOF
    done
  fi
  echo "creating confluent broker pv"
  kubectl apply -f ./broker-pv.yaml
  sleep 10
}

configure_zookeeper () {
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
}
configure_broker () {
  echo "creating confluent brokers"
  local num_of_nodes=$1

  if [[ $num_of_nodes -eq 0 ]]; then
    local replication_factor=1
    yq -o=json '.' ./crs/broker.tpl.yaml | jq --arg replication_factor "$replication_factor" --argjson replication_factor_json "$replication_factor" '.spec.configOverrides.server |= map(gsub("to-be-replaced-with-real-replication-factor"; $replication_factor)) | .spec.metricReporter.replicationFactor = $replication_factor_json | .spec.replicas = $replication_factor_json | .spec.podTemplate.tolerations += [{ "key": "node-role.kubernetes.io/control-plane", "operator": "Equal", "effect": "NoSchedule" }]' > ./crs/broker.json
  else
    local replication_factor=$num_of_nodes
    yq -o=json '.' ./crs/broker.tpl.yaml | jq --arg replication_factor "$replication_factor" --argjson replication_factor_json "$replication_factor" '.spec.configOverrides.server |= map(gsub("to-be-replaced-with-real-replication-factor"; $replication_factor)) | .spec.metricReporter.replicationFactor = $replication_factor_json | .spec.replicas = $replication_factor_json' > ./crs/broker.json
  fi

  kubectl apply -n confluent -f crs/broker.json || kubectl apply -n confluent -f crs/broker.json
  sleep 10

  echo "patching confluent brokers"
  if [[ $num_of_nodes -eq 0 ]]; then
    kubectl patch -n confluent pvc/data0-kafka-0 -p '{"spec":{"volumeName":"data-broker0-volume"}}'
  else
    local n
    for n in $(seq 0 $((num_of_nodes - 1))); do
      local pvc_name="data-broker$n-volume"
      local patch='{"spec":{"volumeName":"'"$pvc_name"'"}}'
      # apparently escaping the quotes \'$patch\' is not needed
      kubectl patch -n confluent pvc/data0-kafka-$n -p "$patch"
    done
  fi

  sleep 2
  configure_broker_pv $num_of_nodes
  sleep 2

  echo "recycling confluent brokers"
  if [[ $num_of_nodes -eq 0 ]]; then
    kubectl delete -n confluent pod/kafka-0
  else
    for n in $(seq 0 $((num_of_nodes - 1))); do
      kubectl delete -n confluent pod/kafka-$n
    done
  fi
}

configure_crs () {
  echo "enabling confluent crs"
  local num_of_nodes=$1

  if [[ $num_of_nodes -eq 0 ]]; then
    local replication_factor=1
    yq -o=json '.' ./crs/connect.tpl.yaml | jq --arg replication_factor "$replication_factor" --argjson replication_factor_json "$replication_factor" '.spec.configOverrides.server |= map(gsub("to-be-replaced-with-real-replication-factor"; $replication_factor)) | .spec.podTemplate.tolerations += [{ "key": "node-role.kubernetes.io/control-plane", "operator": "Equal", "effect": "NoSchedule" }]' > ./crs/connect.json
    yq -o=json '.' ./crs/schemaregistry.tpl.yaml | jq --arg replication_factor "$replication_factor" --argjson replication_factor_json "$replication_factor" '.spec.configOverrides.server |= map(gsub("to-be-replaced-with-real-replication-factor"; $replication_factor)) | .spec.podTemplate.tolerations += [{ "key": "node-role.kubernetes.io/control-plane", "operator": "Equal", "effect": "NoSchedule" }]' > ./crs/schemaregistry.json
  else
    local replication_factor=$num_of_nodes
    yq -o=json '.' ./crs/connect.tpl.yaml | jq --arg replication_factor "$replication_factor" --argjson replication_factor_json "$replication_factor" '.spec.configOverrides.server |= map(gsub("to-be-replaced-with-real-replication-factor"; $replication_factor))' > ./crs/connect.json
    yq -o=json '.' ./crs/schemaregistry.tpl.yaml | jq --arg replication_factor "$replication_factor" --argjson replication_factor_json "$replication_factor" '.spec.configOverrides.server |= map(gsub("to-be-replaced-with-real-replication-factor"; $replication_factor))' > ./crs/schemaregistry.json
  fi
  kubectl apply -n confluent -f crs/connect.json || kubectl apply -n confluent -f crs/connect.json
  kubectl apply -n confluent -f crs/schemaregistry.json || kubectl apply -n confluent -f crs/schemaregistry.json

  sed "s/replace-with-real-postgres-password/$POSTGRES_PASSWORD/" ./crs/postgressink.tpl.yaml > ./crs/postgressink.yaml
  kubectl apply -n confluent -f crs/postgressink.yaml || kubectl apply -n confluent -f crs/postgressink.yaml
}

check_status () {
local namespace=$1
local resource=$2
local rollout_status_cmd="kubectl rollout status -n $namespace $resource"
local attempts=0

until $rollout_status_cmd || [ $attempts -gt 60 ]; do
  $rollout_status_cmd
  attempts=$((attempts + 1))
  sleep 10
done
}

main () {
  echo "uniq_id is injected in as $uniq_id"
  bootstrap
  load_config
  extract_settings
  add_custom_label
  create_namespace
  create_sc
  create_pv
  create_secret
  pushd infra-helm-charts
  git checkout feature/l3a-v3-install
  install_cert_manager
  install_ingress_nginx
  install_postgres
  install_superset
  install_prometheus
  install_grafana
  install_cfk
  configure_zookeeper
  check_status confluent "statefulset.apps/zookeeper"
  configure_broker $nodes
  check_status confluent "statefulset.apps/kafka"
  configure_crs $nodes
  check_status confluent "statefulset.apps/connect"
  check_status confluent "statefulset.apps/schemaregistry"
}

main
