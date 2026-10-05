# Build the upstream gateway from the upstream source bundled in the manager Release.
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS upstream-build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY build-context/upstream/go.mod ./
RUN go mod download
COPY build-context/upstream/ ./
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /out/wb2api ./cmd/server

# Runtime dependencies for the manager-side FastAPI service.
FROM python:3.12-slim AS manager-runtime
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git openssh-client \
 && rm -rf /var/lib/apt/lists/*
COPY build-context/server/requirements.txt /app/server/requirements.txt
RUN pip install --no-cache-dir -r /app/server/requirements.txt
COPY build-context/server /app/server
COPY build-context/web/out /app/web/out
COPY build-context/deploy /app/deploy
COPY build-context/CHANGELOG.md build-context/README.md /app/
RUN useradd -u 10001 -m -s /bin/sh app \
 && mkdir -p /app/data /opt/workbuddy2api/auths /opt/workbuddy2api/data \
 && chown -R 10001:10001 /app /opt/workbuddy2api

FROM manager-runtime
USER root
COPY --from=upstream-build /out/wb2api /opt/workbuddy2api/wb2api
COPY build-context/upstream/config.example.json /opt/workbuddy2api/config.example.json
COPY deploy/workbuddy/workbuddy-manager-single/start-upstream.sh /opt/workbuddy2api/start-upstream.sh
COPY deploy/workbuddy/workbuddy-manager-single/stop-upstream.sh /opt/workbuddy2api/stop-upstream.sh
COPY deploy/workbuddy/workbuddy-manager-single/entrypoint.sh /entrypoint-combined.sh
# Include task-runner scripts used by the manager's growth-task feature.
COPY build-context/upstream/scripts/ /opt/workbuddy2api/scripts/
RUN chmod 755 /opt/workbuddy2api/*.sh /opt/workbuddy2api/wb2api /entrypoint-combined.sh \
 && chown -R 10001:10001 /opt/workbuddy2api /entrypoint-combined.sh
ENV WB2API_MODE=native \
    WB2API_BASE=http://127.0.0.1:7863 \
    WB_UPSTREAM_DIR=/opt/workbuddy2api \
    WB_AUTH_DIR=/opt/workbuddy2api/auths \
    WB_UPSTREAM_CONFIG=/opt/workbuddy2api/config.json \
    WB2API_START_SCRIPT=/opt/workbuddy2api/start-upstream.sh \
    WB2API_STOP_SCRIPT=/opt/workbuddy2api/stop-upstream.sh \
    WB2API_LOG_FILE=/opt/workbuddy2api/data/server.err.log \
    WB_INSTALL_DIR=/app \
    WB_DATA_DIR=/app/data \
    WB_STATIC_DIR=/app/web/out
USER 10001:10001
EXPOSE 7864 7863
ENTRYPOINT ["/entrypoint-combined.sh"]
