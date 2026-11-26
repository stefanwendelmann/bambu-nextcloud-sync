# syntax=docker/dockerfile:1

# Official rclone image, pinned by version and multi-arch digest. Dependabot proposes updates.
FROM rclone/rclone:1.76.0@sha256:7cbeec24a44f206067597c0368be4de90ae19a64d5113c7d1938bd737a81e466 AS base
RUN apk add --no-cache curl jq
COPY src/ /app/
RUN chmod 0755 /app/*.sh && mkdir -p /data
ENV DATA_DIR=/data \
    TZ=UTC
VOLUME ["/data"]
ENTRYPOINT ["/app/entrypoint.sh"]

# Unit tests run inside the real runtime environment: docker build --target test .
FROM base AS test
COPY tests/unit/ /tests/unit/
RUN sh /tests/unit/run.sh

FROM base AS runtime
