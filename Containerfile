# Resolved by setup.sh at build time; defaults are the pinned fallback.
ARG OPENCODE_TAG=2.3.2
FROM ghcr.io/anomalyco/opencode:${OPENCODE_TAG}

RUN apk add --no-cache git ca-certificates curl bash jq file xz nodejs npm python3 py3-pip

# User-installed tools persist here: $DATA/bin is mounted over it in every
# container (service, shell and sessions).
ENV PATH=/root/.local/bin:$PATH
ENV SHELL=/bin/bash
