#!/usr/bin/env bash

export HOME=/root
export KUBECONFIG=/etc/kubernetes/admin.conf

cat << EOF > features-sa.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: connector
  namespace: l3a-v3
EOF
kubectl apply -f ./features-sa.yaml

while read feature; do
  [ -d "$(basename $(jq -r .helmValuesRepo <<< $feature) .git)" ] || git clone https://$gh_username:$gh_pat@$(jq -r .helmValuesRepo <<< $feature)
  helm repo add $(jq -r .helmRepoName <<< $feature)  $(jq -r .helmRepoUrl <<< $feature)
  while read workload; do
    $(jq -r .command <<< $feature) -n $(jq -r .namespace <<< $feature) $workload $(jq -r .helmRepoName <<< $feature)/$(jq -r .helmChartName <<< $feature) \
      $(jq -r .args <<< $feature) \
      -f $(basename $(jq -r .helmValuesRepo <<< $feature) .git)/$(jq -r .pathToChart <<< $feature)/$(jq -r .name <<< $feature)/$workload-values.yaml
  done <<< $(jq -r .workloads[] <<< $feature)
done <<< $(jq -c .[] features.json)
