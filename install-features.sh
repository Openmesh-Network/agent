#!/usr/bin/env bash

bootstrap () {
  export PRODUCT_NAME=openmesh
}

load_config () {
  while [ ! -f infra_config.json ]
  do
    inotifywait -qqt 2 -e create -e moved_to "$(dirname infra_config.json)"
    echo "infra_config.json file not found, cowardly looping"
  done
  while [ ! -f features.json ]
  do
    inotifywait -qqt 2 -e create -e moved_to "$(dirname features.json)"
    echo "features.json file not found, cowardly looping"
  done

  readonly INFRA_CONFIG=$(< infra_config.json)
  readonly FEATURES=$(< features.json)
}

extract_settings () {
  export single_xnode=$(jq -r .single_xnode <<< $INFRA_CONFIG)
}

install_features () {
  cat << EOF > features-sa.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: connector
  namespace: $PRODUCT_NAME
EOF
  kubectl apply -f ./features-sa.yaml

  while read feature; do
    [ -d "$(basename $(jq -r .helmValuesRepo <<< $feature) .git)" ] || git clone https://$gh_username:$gh_pat@$(jq -r .helmValuesRepo <<< $feature)
    echo helm repo add \
      $(jq -r .helmRepoName <<< $feature) \
      $(jq -r .helmRepoUrl <<< $feature)
    helm repo add \
      $(jq -r .helmRepoName <<< $feature) \
      $(jq -r .helmRepoUrl <<< $feature)

    echo helm dependency build
    helm dependency build

    while read workload; do
      echo $(jq -r .command <<< $feature) -n $(jq -r .namespace <<< $feature) $workload $(jq -r .helmRepoName <<< $feature)/$(jq -r .helmChartName <<< $feature) \
        $(jq -r .args <<< $feature) \
        -f $(basename $(jq -r .helmValuesRepo <<< $feature) .git)/$(jq -r .pathToChart <<< $feature)/$(jq -r .name <<< $feature)/$workload-values.yaml

      $(jq -r .command <<< $feature) -n $(jq -r .namespace <<< $feature) $workload $(jq -r .helmRepoName <<< $feature)/$(jq -r .helmChartName <<< $feature) \
        $(jq -r .args <<< $feature) \
        -f $(basename $(jq -r .helmValuesRepo <<< $feature) .git)/$(jq -r .pathToChart <<< $feature)/$(jq -r .name <<< $feature)/$workload-values.yaml
    done <<< $(jq -r .workloads[] <<< $feature)
  done <<< $(jq -c .[] <<< $FEATURES)
}

main () {
  bootstrap
  load_config
  extract_settings
  if [[ $single_xnode == false ]]; then install_features; fi
}

main
