# ========================= Common Args =========================
ARG OS_VERSION="24.04"
ARG LIBFABRIC_VERSION="1.18.1"
ARG MPICH_VERSION="3.4.3"
ARG MPI4PY_VERSION="3.1.5"
ARG LUSTRE_TAG="v2_15_0"      # choose a stable tag/ref
ARG ROCM_VERSION="6.4.1"      # fixed to noble
ARG ENABLE_OSU="0"            # 0 = don't build OSU, 1 = build
ARG GFX_ARCH="gfx90a"

# ====================== Stage 1: Lustre userspace ======================
FROM ubuntu:${OS_VERSION} AS lustre-builder
ENV DEBIAN_FRONTEND=noninteractive

# Build deps for Lustre userspace
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    build-essential git autoconf automake libtool m4 pkg-config \
    libyaml-dev libkeyutils-dev uuid-dev zlib1g-dev \
    ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

ARG LUSTRE_TAG
WORKDIR /tmp/lustre

# Fetch Lustre (git://) with simple retries
RUN set -e; \
  for i in 1 2 3; do \
    echo "Cloning Lustre (attempt $i)..." && \
    git clone --depth 1 --branch "${LUSTRE_TAG}" git://git.whamcloud.com/fs/lustre-release.git . && break || { \
      echo "Clone failed (attempt $i). Retrying in 5s..."; sleep 5; \
    }; \
  done

# Build userspace (liblustreapi + utils) only
RUN ./autogen.sh \
 && ./configure --prefix=/opt/lustre \
      --disable-server --disable-tests --disable-modules \
      --without-ldiskfs --without-zfs \
 && make -C lustre/utils -j"$(nproc)" \
 && make -C lustre/utils install

# ====================== Stage 2: Core builder (HPC stack) ======================
FROM ubuntu:${OS_VERSION} AS core-builder
ENV DEBIAN_FRONTEND=noninteractive

ARG LIBFABRIC_VERSION
ARG MPICH_VERSION
ARG ENABLE_OSU

# Build deps for libfabric/MPICH/aws-ofi-rccl/OSU
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    build-essential gcc-12 g++-12 gfortran-12 \
    git wget curl ca-certificates pkg-config \
    autoconf automake libtool m4 make bison flex \
    libnuma-dev zlib1g-dev libssl-dev libreadline-dev \
    python3 python3-pip python3-dev swig \
    ninja-build \
 && rm -rf /var/lib/apt/lists/*

# Modern CMake (build-only)
RUN wget -q https://github.com/Kitware/CMake/releases/download/v3.31.7/cmake-3.31.7-linux-x86_64.sh \
 && chmod +x cmake-3.31.7-linux-x86_64.sh \
 && ./cmake-3.31.7-linux-x86_64.sh --skip-license --prefix=/usr \
 && cmake --version \
 && rm -f cmake-3.31.7-linux-x86_64.sh

# Bring Lustre userspace (headers + liblustreapi) for MPICH ROMIO detection
COPY --from=lustre-builder /opt/lustre /opt/lustre

WORKDIR /tmp/build

# -------- Build libfabric --------
ARG LIBFABRIC_PREFIX="/opt/libfabric"
RUN wget -q https://github.com/ofiwg/libfabric/archive/refs/tags/v${LIBFABRIC_VERSION}.tar.gz \
 && tar xf v${LIBFABRIC_VERSION}.tar.gz \
 && cd libfabric-${LIBFABRIC_VERSION} \
 && ./autogen.sh && ./configure --prefix=${LIBFABRIC_PREFIX} \
 && make -j"$(nproc)" && make install-strip

# -------- Build MPICH (with Lustre ROMIO + your patches) --------
COPY mpich_patches.tgz /tmp/build/
ARG MPICH_PREFIX="/opt/mpich"
RUN wget -q http://www.mpich.org/static/downloads/${MPICH_VERSION}/mpich-${MPICH_VERSION}.tar.gz \
 && tar xf mpich-${MPICH_VERSION}.tar.gz \
 && cd mpich-${MPICH_VERSION} \
 && tar xf /tmp/build/mpich_patches.tgz \
 && patch -p0 < csel.patch \
 && patch -p0 < ch4r_init.patch \
 && CPPFLAGS="-I/opt/lustre/include" LDFLAGS="-L/opt/lustre/lib" LIBS="-llustreapi" \
    ./configure --prefix=${MPICH_PREFIX} \
      --without-mpe --enable-fortran=all --enable-shared \
      --with-device=ch4:ofi --with-file-system=ufs+lustre+nfs \
      CC=gcc-12 CXX=g++-12 FC=gfortran-12 FFLAGS=-fallow-argument-mismatch \
 && make -j"$(nproc)" && make install-strip

# -------- Build aws-ofi-rccl --------
ARG AWS_OFI_RCCL_PREFIX="/opt/aws-ofi-rccl"
RUN git clone --depth 1 https://github.com/ROCmSoftwarePlatform/aws-ofi-rccl.git \
 && cd aws-ofi-rccl && ./autogen.sh \
 && PKG_CONFIG_PATH=${LIBFABRIC_PREFIX}/lib/pkgconfig ./configure \
      --prefix=${AWS_OFI_RCCL_PREFIX} \
      --with-mpi=${MPICH_PREFIX} --with-libfabric=${LIBFABRIC_PREFIX} \
      CFLAGS="-O2 -D__HIP_PLATFORM_AMD__" CXXFLAGS="-O2 -D__HIP_PLATFORM_AMD__" \
 && make -j"$(nproc)" && make install-strip

# -------- Optionally build OSU microbenchmarks --------
ARG OSU_VERSION="7.3"
ARG OSU_PREFIX="/opt/osu"
RUN if [ "${ENABLE_OSU}" = "1" ]; then \
      wget -q http://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_VERSION}.tar.gz && \
      tar xf osu-micro-benchmarks-${OSU_VERSION}.tar.gz && \
      cd osu-micro-benchmarks-${OSU_VERSION} && \
      ./configure --prefix=${OSU_PREFIX} \
         CC=${MPICH_PREFIX}/bin/mpicc CXX=${MPICH_PREFIX}/bin/mpicxx \
         CFLAGS="-O3" && \
      make -j"$(nproc)" && make install-strip ; \
    fi

# ====================== Stage 3: Runtime (slim, bash shell) ======================
FROM ubuntu:${OS_VERSION} AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

# ---- Minimal runtime deps ----
RUN set -e \
 && apt-get update -qq \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates wget gnupg lsb-release \
      libnuma1 libgfortran5 libgcc-s1 libstdc++6 \
      libyaml-0-2 keyutils \
      python3 python3-pip python3-venv \
      rsync tzdata \
 && rm -rf /var/lib/apt/lists/*

# ---- ROCm 6.4.1 HIP runtime installation ----
ARG ROCM_VERSION
RUN set -e \
 && apt-get update -qq \
 && ROCM_DEB="amdgpu-install_6.4.60401-1_all.deb" \
 && URL="https://repo.radeon.com/amdgpu-install/${ROCM_VERSION}/ubuntu/noble/${ROCM_DEB}" \
 && echo "Fetching ${URL}" \
 && wget -q -O "/tmp/${ROCM_DEB}" "${URL}" \
 && dpkg -i "/tmp/${ROCM_DEB}" || true \
 && apt-get -f install -y \
 && dpkg -i "/tmp/${ROCM_DEB}" \
 && mkdir -p /var/cache/apt/archives/partial \
 && amdgpu-install -y --usecase=rocm,hip-runtime --no-dkms \
 && rm -f "/tmp/${ROCM_DEB}" \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /root/.cache

# ---- Copy runtime libraries ----
COPY --from=lustre-builder /opt/lustre/lib/liblustreapi.so* /opt/lustre/lib/
COPY --from=core-builder   /opt/libfabric /opt/libfabric
COPY --from=core-builder   /opt/mpich    /opt/mpich
COPY --from=core-builder   /opt/aws-ofi-rccl /opt/aws-ofi-rccl
COPY --from=core-builder   /opt/osu      /opt/osu

# ---- Environment paths ----
ENV PATH=/opt/mpich/bin:$PATH
ENV LD_LIBRARY_PATH=/opt/lustre/lib:/opt/libfabric/lib:/opt/mpich/lib:/opt/aws-ofi-rccl/lib:$LD_LIBRARY_PATH

# ---- OSU benchmark PATH (if available) ----
RUN if [ -d /opt/osu/libexec/osu-micro-benchmarks/mpi/pt2pt ]; then \
      echo 'export PATH=/opt/osu/libexec/osu-micro-benchmarks/mpi/pt2pt:/opt/osu/libexec/osu-micro-benchmarks/mpi/collective:$PATH' >> /etc/profile.d/90-osu.sh ; \
    fi

# ---- mpi4py ----
ARG MPI4PY_VERSION
RUN pip install --no-cache-dir mpi4py==${MPI4PY_VERSION}

# ---- Cleanup docs/locales ----
RUN rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/locale/* || true

# ---- Environment variables ----
ENV NCCL_SOCKET_IFNAME=hsn \
    CXI_FORK_SAFE=1 \
    CXI_FORK_SAFE_HP=1 \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    FI_CXI_DISABLE_CQ_HUGETLB=1 \
    ROCM_PATH=/opt/rocm

# ---- GPU arch shim for non-GPU hosts ----
ARG GFX_ARCH
RUN printf '#!/bin/bash\necho %s\n' "${GFX_ARCH}" > /usr/local/bin/amdgpu-arch && chmod +x /usr/local/bin/amdgpu-arch && \
    printf '#!/bin/bash\necho %s\n' "${GFX_ARCH}" > /usr/local/bin/rocm_agent_enumerator && chmod +x /usr/local/bin/rocm_agent_enumerator

# ---- Singularity env injection ----
RUN mkdir -p /.singularity.d/env/ && \
    echo "export NCCL_SOCKET_IFNAME=hsn"              >> /.singularity.d/env/91-environment.sh && \
    echo "export CXI_FORK_SAFE=1"                     >> /.singularity.d/env/91-environment.sh && \
    echo "export ROCM_PATH=/opt/rocm"                 >> /.singularity.d/env/91-environment.sh && \
    echo "export CXI_FORK_SAFE_HP=1"                  >> /.singularity.d/env/91-environment.sh && \
    echo "export HSA_FORCE_FINE_GRAIN_PCIE=1"         >> /.singularity.d/env/91-environment.sh && \
    echo "export FI_CXI_DISABLE_CQ_HUGETLB=1"         >> /.singularity.d/env/91-environment.sh

WORKDIR /workspace
LABEL org.opencontainers.image.version=0.0.5 org.opencontainers.image.devmode=true org.opencontainers.image.noscan=true org.opencontainers.image.platform=x86
