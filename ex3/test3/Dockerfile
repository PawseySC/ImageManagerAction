# use node:10
FROM debian:stretch

# install some common tools (these packages have many vulnerabilities in node:10)
RUN set -eux; \
    sed -i 's|deb.debian.org/debian|archive.debian.org/debian|g' /etc/apt/sources.list; \
    sed -i 's|security.debian.org/debian-security|archive.debian.org/debian-security|g' /etc/apt/sources.list; \
    sed -i '/stretch-updates/d' /etc/apt/sources.list; \
    printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99no-check-valid; \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*
# default command
CMD ["node", "-v"]
LABEL org.opencontainers.image.version=0.0.25 org.opencontainers.image.devmode=true org.opencontainers.image.noscan=true org.opencontainers.image.platform=x86
