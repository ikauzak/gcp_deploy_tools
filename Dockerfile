FROM google/cloud-sdk:alpine

RUN apk add -U openssl curl tar gzip bash ca-certificates \
    && curl https://kubernetes-helm.storage.googleapis.com/helm-v2.16.0-linux-amd64.tar.gz | tar zx \
    && mv linux-amd64/helm /usr/bin/ \
    && gcloud components install kubectl

COPY scripts /scripts
