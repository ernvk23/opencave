# Pulls the tag from .env; pin it there if a release breaks.
ARG OPENCODE_TAG=2.3.2
FROM ghcr.io/anomalyco/opencode:${OPENCODE_TAG}

RUN apk upgrade --no-cache \
 && apk add --no-cache git ca-certificates curl bash jq file xz nodejs npm python3 py3-pip

# User-installed tools persist here: $DATA/bin is mounted over it in every
# container (service, shell and sessions).
ENV PATH=/root/.local/bin:$PATH
ENV SHELL=/bin/bash
