FROM alpine:3

ARG SUPERCRONIC_VERSION=v0.2.49
ARG TARGETARCH=amd64

RUN apk add --no-cache curl jq postgresql-client mariadb-client su-exec && \
    case "$TARGETARCH" in \
        amd64) SUPERCRONIC_SHA1=e63c11a9726b775a6a11801e81af4f3fb926aa68 ;; \
        arm64) SUPERCRONIC_SHA1=0b6c5bb743e0b0dafed1132198c81807927ac413 ;; \
        *)     printf 'ERROR: unsupported arch: %s\n' "$TARGETARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSLO "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" && \
    echo "${SUPERCRONIC_SHA1}  supercronic-linux-${TARGETARCH}" | sha1sum -c - && \
    chmod +x "supercronic-linux-${TARGETARCH}" && \
    mv "supercronic-linux-${TARGETARCH}" /usr/local/bin/supercronic && \
    adduser -D -H -s /sbin/nologin backup

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY backup.sh /usr/local/bin/backup.sh
COPY retention.sh /usr/local/bin/retention.sh
COPY qd-snapshot.sh /usr/local/bin/qd-snapshot.sh
COPY tar-backup.sh /usr/local/bin/tar-backup.sh
COPY pg-backup.sh /usr/local/bin/pg-backup.sh
COPY mariadb-backup.sh /usr/local/bin/mariadb-backup.sh
COPY surreal-backup.sh /usr/local/bin/surreal-backup.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
              /usr/local/bin/backup.sh \
              /usr/local/bin/retention.sh \
              /usr/local/bin/qd-snapshot.sh \
              /usr/local/bin/tar-backup.sh \
              /usr/local/bin/pg-backup.sh \
              /usr/local/bin/mariadb-backup.sh \
              /usr/local/bin/surreal-backup.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
