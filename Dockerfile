# mongodump/mongorestore ship no Alpine/musl build (dynamically linked
# against glibc + Kerberos) -- sourced from the official mongo image, whose
# Ubuntu base is verified compatible with this image's own Ubuntu base
# below, rather than fetched from MongoDB's own tools tarball as a second,
# independently-checksummed download path for the same upstream artifact.
FROM mongo:8.0.34@sha256:b9924c330a8bbc5800fe9c69f04a84e221eca7b28fd049a0354147d9908fa142 AS mongotools

FROM ubuntu:26.04@sha256:0e73b71479e7bc5f006bca872e25c3cd680dc052a0116f90d63ae363537db0dd

ARG SUPERCRONIC_VERSION=v0.2.51
ARG GOSU_VERSION=1.19
ARG TARGETARCH=amd64

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq postgresql-client mariadb-client netcat-openbsd libgssapi-krb5-2 \
    && rm -rf /var/lib/apt/lists/* && \
    case "$TARGETARCH" in \
        amd64) SUPERCRONIC_SHA1=1692066e350a88ff4d7d6474fe3c7a6c41ec5e89 ;; \
        arm64) SUPERCRONIC_SHA1=9d4c2000493215a1898502b2fc2dada3e8ea8c7a ;; \
        *)     printf 'ERROR: unsupported arch: %s\n' "$TARGETARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSLO "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" && \
    echo "${SUPERCRONIC_SHA1}  supercronic-linux-${TARGETARCH}" | sha1sum -c - && \
    chmod +x "supercronic-linux-${TARGETARCH}" && \
    mv "supercronic-linux-${TARGETARCH}" /usr/local/bin/supercronic && \
    case "$TARGETARCH" in \
        amd64) GOSU_SHA256=52c8749d0142edd234e9d6bd5237dff2d81e71f43537e2f4f66f75dd4b243dd0 ;; \
        arm64) GOSU_SHA256=3a8ef022d82c0bc4a98bcb144e77da714c25fcfa64dccc57f6aba7ae47ff1a44 ;; \
        *)     printf 'ERROR: unsupported arch: %s\n' "$TARGETARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSLO "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${TARGETARCH}" && \
    echo "${GOSU_SHA256}  gosu-${TARGETARCH}" | sha256sum -c - && \
    chmod +x "gosu-${TARGETARCH}" && \
    mv "gosu-${TARGETARCH}" /usr/local/bin/gosu
# Ubuntu already ships a dedicated, unprivileged "backup" system account
# (uid/gid 34, /usr/sbin/nologin) -- reused as-is, no useradd needed.

# mongodump/mongorestore only -- not the rest of the mongo image's tools
# (mongosh alone is ~190MB, not needed for a headless dump/restore).
COPY --from=mongotools /usr/bin/mongodump /usr/bin/mongorestore /usr/local/bin/

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY src/backup.sh /usr/local/bin/backup.sh
COPY src/retention.sh /usr/local/bin/retention.sh
COPY src/drill.sh /usr/local/bin/drill.sh
COPY src/qd-snapshot.sh /usr/local/bin/qd-snapshot.sh
COPY src/tar-backup.sh /usr/local/bin/tar-backup.sh
COPY src/pg-backup.sh /usr/local/bin/pg-backup.sh
COPY src/mariadb-backup.sh /usr/local/bin/mariadb-backup.sh
COPY src/surreal-backup.sh /usr/local/bin/surreal-backup.sh
COPY src/mongo-backup.sh /usr/local/bin/mongo-backup.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
              /usr/local/bin/backup.sh \
              /usr/local/bin/retention.sh \
              /usr/local/bin/drill.sh \
              /usr/local/bin/qd-snapshot.sh \
              /usr/local/bin/tar-backup.sh \
              /usr/local/bin/pg-backup.sh \
              /usr/local/bin/mariadb-backup.sh \
              /usr/local/bin/surreal-backup.sh \
              /usr/local/bin/mongo-backup.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
