deploy() {
    source deploy.conf
    track="${1-stable}"
    # name="$CIRCLE_PROJECT_REPONAME"
    #
    # if [[ "$track" != "stable" ]]; then
    #   name="$name-$track"
    # fi

    # replicas="1"
    service_enabled="false"
    # # postgres_enabled="$POSTGRES_ENABLED"
    # # canary uses stable db
    # [[ "$track" == "canary" ]] && postgres_enabled="false"
    #
    # env_track=$( echo $track | tr -s  '[:lower:]'  '[:upper:]' )
    # env_slug=$( echo ${CIRCLE_BRANCH//-/_} | tr -s  '[:lower:]'  '[:upper:]' )
    #
    # if echo "$CIRCLE_BRANCH" | egrep "master"; then
    #   env_selector='ENV-PRODUCAO'
    # else
    #   env_selector='ENV-DESENVOLVIMENTO'
    # fi
    #
    # if [[ "$track" == "stable" ]]; then
    #   # for stable track get number of replicas from `PRODUCTION_REPLICAS`
    #   eval new_replicas=\$${env_slug}_REPLICAS
    #   service_enabled="true"
    # else
    #   # for all tracks get number of replicas from `CANARY-production_REPLICAS`
    #   eval new_replicas=\$${env_track}_${env_slug}_REPLICAS
    # fi
    # if [[ -n "$new_replicas" ]]; then
    #   replicas="$new_replicas"
    # fi

    # WORKAROUND - Ajuste para problemas com RBAC. Referência: https://gitlab.com/charts/charts.gitlab.io/issues/118 e https://gitlab.com/gitlab-org/gitlab-ce/issues/44597

    # kubectl get clusterrolebinding $KUBE_NAMESPACE-cluster-rule || kubectl create clusterrolebinding $KUBE_NAMESPACE-cluster-rule --clusterrole=cluster-admin --serviceaccount=$KUBE_NAMESPACE:default


    helm upgrade --install \
      --set service.enabled="$service_enabled" \
      --set ingress.enabled="$ingress_enabled" \
      --set releaseOverride="$CI_ENVIRONMENT" \
      --set image.repository="$CI_APPLICATION_REPOSITORY" \
      --set image.tag="$CI_APPLICATION_TAG" \
      --set image.pullPolicy=IfNotPresent \
      --set application.track="$track" \
      --set service.build_name="$CI_BUILD_NAME" \
      --set replicaCount="$replicas" \
      --set resources.requests.memory="$MEMORY_REQUEST" \
      --set resources.requests.cpu="$CPU_REQUEST" \
      --set resources.limits.memory="$MEMORY_LIMIT" \
      --set resources.limits.cpu="$CPU_LIMIT" \
      --namespace="$KUBE_NAMESPACE" \
      "$KUBE_NAMESPACE" \
      chart/
      # --set service.url="$CI_ENVIRONMENT_URL" \
      # --version="$CI_PIPELINE_ID-$CI_JOB_ID" \
      # --set application.environment="$env_selector" \
      # --set service.internalPort="$INTERNAL_PORT" \
      # --set service.externalPort="$EXTERNAL_PORT" \
      # --set application.database_url="$DATABASE_URL" \
      # --set application.application_name="$APPLICATION_NAME" \
      # --set service.healthcheck.endpoint="$SERVICE_HEALTHCHECK_ENDPOINT" \
      # --set postgresql.enabled="$postgres_enabled" \
      # --set postgresql.nameOverride="postgres" \
      # --set postgresql.postgresUser="$POSTGRES_USER" \
      # --set postgresql.postgresPassword="$POSTGRES_PASSWORD" \
      # --set postgresql.postgresDatabase="$POSTGRES_DB" \
      # --set livenessprobe.initialDelaySeconds="$LIVENESS_PROBE_INITIAL_DELAY_SEC" \
      # --set readinessprobe.initialDelaySeconds="$READINESS_PROBE_INITIAL_DELAY_SEC" \
      # --set persistence.enabled="$PERSISTENCE_ENABLED" \
      # --set persistence.size="$PERSISTENCE_SIZE" \
      # --set persistence.path="$PERSISTENCE_PATH" \
      # --set service.probe.healthcheck="$HEALTH_CHECK_ENDPOINT" \

    count=0
    while (( count < 50 )); do
      if ! kubectl rollout status -n "$KUBE_NAMESPACE" "deployment/$KUBE_NAMESPACE" --watch=false | grep -i "success" ; then
         echo "Checking deployment on Kubernetes, please wait..."
         sleep 5;
         count=$((count+1))
         if (( count == 50 )); then
            echo "Was not able to get READY status from Kubernetes so far, please check your POD status"
            exit 1
         fi
      else
         count=50
      fi
    done

}

cluster_auth() {
  echo "Authenticating in gcloud..."
  echo $GOOGLE_CLUSTER_SA > auth.json
  gcloud auth activate-service-account --key-file=auth.json --quiet

  echo "Getting cluster credentials..."
  gcloud container clusters get-credentials $GOOGLE_CLUSTER_NAME --region $GOOGLE_COMPUTE_ZONE --project $GOOGLE_PROJECT_ID --quiet
}

install_dependencies() {
    helm version --client
    kubectl version --client
}


download_chart() {
    # if [[ ! -d chart ]]; then
    helm init --client-only
    git clone ${CHART_REPO_URL} chart
    # helm dependency update chart/
    # helm dependency build chart/
  }

ensure_namespace() {
        kubectl get namespace "$KUBE_NAMESPACE" || kubectl create namespace "$KUBE_NAMESPACE"
  }

check_kube_domain() {
    if [ -z ${AUTO_DEVOPS_DOMAIN+x} ]; then
      echo "Domínio para deploy não definido. Um domínio deve ser definido na variável AUTO_DEVOPS_DOMAIN no SECRETS"
      false
    else
      true
    fi
  }

check_url_app() {
    # Se nao definido URL_APP assume o default CI_PROJECT_PATH_SLUG
    if [ -z ${APPLICATION_NAME+x} ]; then
      echo "ERRO!! - Variavel APPLICATION_NAME nao foi definida no SECRETS!!!!"
      false
    fi
    echo "Nome da aplicacao: $APPLICATION_NAME"
  }

install_tiller() {
    echo "Checking Tiller..."
    helm init --upgrade
    kubectl rollout status -n "$TILLER_NAMESPACE" -w "deployment/tiller-deploy"
    if ! helm version --debug; then
      echo "Failed to init Tiller."
      return 1
    fi
    echo ""
}

create_secret() {
    echo "Create secret..."
    if [[ "$CI_PROJECT_VISIBILITY" == "public" ]]; then
       return
    fi

     # Cria secret para primeiro deployment via HELM. Esta secret só funciona no primeiro deploy devido a natureza do gitlab-ci-token. Deploys subsequentes utiulizarão outra secret válida para o usuário registryuser (criada por um cronjob)
    if ! kubectl get secret -n "$KUBE_NAMESPACE" gitlab-registry || kubectl get secret gitlab-registry -n "$KUBE_NAMESPACE" --output="jsonpath={.data.\.dockerconfigjson}" | base64 -d | grep gitlab-ci-token ; then
    echo "Criando Secret..."
    kubectl create secret -n "$KUBE_NAMESPACE" \
      docker-registry gitlab-registry \
      --docker-server="$CI_REGISTRY" \
      --docker-username="$CI_REGISTRY_USER" \
      --docker-password="$CI_REGISTRY_PASSWORD" \
      --docker-email="$GITLAB_USER_EMAIL" \
      -o yaml --dry-run | kubectl replace -n "$KUBE_NAMESPACE" --force -f -
     fi
}

delete() {
    track="${1-stable}"
    name="$CI_ENVIRONMENT_SLUG"

    if [[ "$track" != "stable" ]]; then
      name="$name-$track"
    fi

    helm delete "$name" || true
}
