# ---- Template parameters ----
ARG DEBIAN_VERSION=stretch
ARG CURL_ENABLED=no

FROM debian:${DEBIAN_VERSION}

# Keep args available (for ENV + runtime echo)
ARG DEBIAN_VERSION
ARG CURL_ENABLED

ENV DEBIAN_VERSION=${DEBIAN_VERSION} \
    CURL_ENABLED=${CURL_ENABLED}


RUN set -eux; \
    sed -i 's|deb.debian.org/debian|archive.debian.org/debian|g' /etc/apt/sources.list; \
    sed -i 's|security.debian.org/debian-security|archive.debian.org/debian-security|g' /etc/apt/sources.list; \
    sed -i '/stretch-updates/d' /etc/apt/sources.list; \
    printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99no-check-valid; \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*


RUN echo '#!/bin/sh' > /show-info.sh \
 && echo 'set -eu' >> /show-info.sh \
 && echo '. /etc/os-release >/dev/null 2>&1 || true' >> /show-info.sh \
 && echo 'echo "DEBIAN_VERSION(ARG/ENV): ${DEBIAN_VERSION:-unknown}"' >> /show-info.sh \
 && echo 'echo "CURL_ENABLED(ARG/ENV): ${CURL_ENABLED:-unknown}"' >> /show-info.sh \
 && echo 'echo "OS: ${PRETTY_NAME:-unknown}"' >> /show-info.sh \
 && echo 'if command -v curl >/dev/null 2>&1; then curl --version | head -n1; else echo "curl not installed"; fi' >> /show-info.sh \
 && chmod +x /show-info.sh

CMD ["/show-info.sh"]
LABEL org.opencontainers.image.version=0.0.7 org.opencontainers.image.devmode=false org.opencontainers.image.noscan=false org.opencontainers.image.platform=x86
