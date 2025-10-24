# ========================= Common Args =========================
ARG OS_VERSION="24.04"
ARG LINUX_KERNEL="6.8.0-31"
ARG LIBFABRIC_VERSION="1.18.1"
ARG MPICH_VERSION="3.4.3"
ARG MPI4PY_VERSION="3.1.5"
ARG ROCM_VERSION="6.4.1"
ARG ENABLE_OSU="1"
ARG GFX_ARCH="gfx90a"

# ====================== Stage 1: Build Lustre ======================
FROM ubuntu:${OS_VERSION} AS lustre-builder
ARG LINUX_KERNEL
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies for Lustre
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    build-essential gcc g++ gfortran \
    git wget curl ca-certificates \
    autoconf automake libtool m4 pkg-config bison flex \
    libkeyutils-dev libnl-genl-3-dev libyaml-dev \
    libmount-dev zlib1g-dev \
    linux-headers-${LINUX_KERNEL}-generic linux-headers-${LINUX_KERNEL} \
    fakeroot devscripts dpkg-dev \
 && rm -rf /var/lib/apt/lists/*

# Generate kernel config for Lustre build
RUN echo "deb-src http://archive.ubuntu.com/ubuntu noble main restricted" >> /etc/apt/sources.list \
 && apt-get update -qq \
 && cd /tmp \
 && apt-get source linux \
 && cd linux-* \
 && chmod +x ./debian/scripts/misc/annotations \
 && ./debian/scripts/misc/annotations --arch amd64 --flavour generic --export > .config \
 && cp .config /usr/lib/modules/${LINUX_KERNEL}-generic/build/ \
 && cd /tmp && rm -rf linux-*

# Build Lustre from GitHub mirror (more reliable than git.whamcloud.com)
WORKDIR /tmp/lustre-build
RUN set -e; \
  for i in 1 2 3; do \
    echo "Cloning Lustre from GitHub (attempt $i)..." && \
    git clone --depth 1 https://github.com/lustre/lustre-release.git && break || { \
      echo "Clone failed (attempt $i). Retrying in 5s..."; sleep 5; \
    }; \
  done

RUN cd lustre-release \
 && bash autogen.sh \
 && ./configure --disable-server --enable-client \
      --with-linux=/usr/lib/modules/${LINUX_KERNEL}-generic/build \
      --disable-tests \
      CFLAGS=-Wno-error=attribute-warning \
 && make -j"$(nproc)" \
 && make install

# ====================== Stage 2: Build MPI stack ======================
FROM ubuntu:${OS_VERSION} AS mpi-builder
ARG LIBFABRIC_VERSION
ARG MPICH_VERSION
ARG ENABLE_OSU
ARG ROCM_VERSION
ARG GFX_ARCH
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    build-essential gcc-12 g++-12 gfortran-12 \
    git wget curl ca-certificates pkg-config gnupg lsb-release \
    autoconf automake libtool m4 make bison flex \
    libnuma-dev zlib1g-dev libssl-dev libreadline-dev \
    python3 python3-pip python3-dev swig ninja-build \
 && rm -rf /var/lib/apt/lists/*

# Install ROCm development packages for building aws-ofi-rccl and OSU
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
 && amdgpu-install -y --usecase=hiplibsdk,rocm --no-dkms --no-32 \
 && rm -f "/tmp/${ROCM_DEB}" \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# GPU arch shim for building on non-GPU hosts (needed during build)
RUN cd /opt/rocm/bin && \
    mv rocm_agent_enumerator rocm_agent_enumerator.orig && \
    echo "echo ${GFX_ARCH}" > rocm_agent_enumerator && \
    chmod +x rocm_agent_enumerator && \
    cd /opt/rocm/lib/llvm/bin && \
    mv amdgpu-arch amdgpu-arch.orig && \
    echo "echo ${GFX_ARCH}" > amdgpu-arch && \
    chmod +x amdgpu-arch

# Modern CMake
RUN wget -q https://github.com/Kitware/CMake/releases/download/v3.31.7/cmake-3.31.7-linux-x86_64.sh \
 && chmod +x cmake-3.31.7-linux-x86_64.sh \
 && ./cmake-3.31.7-linux-x86_64.sh --skip-license --prefix=/usr \
 && cmake --version \
 && rm -f cmake-3.31.7-linux-x86_64.sh

WORKDIR /tmp/build

# Copy Lustre from default install location (/usr/local)
RUN mkdir -p /usr/local/include/linux /usr/local/lib/pkgconfig
COPY --from=lustre-builder /usr/local/include/lustre /usr/local/include/lustre
COPY --from=lustre-builder /usr/local/include/linux/lustre /usr/local/include/linux/lustre
COPY --from=lustre-builder /usr/local/lib/liblustreapi* /usr/local/lib/
COPY --from=lustre-builder /usr/local/lib/pkgconfig/ /usr/local/lib/pkgconfig/
RUN ldconfig

# Build libfabric
RUN wget -q https://github.com/ofiwg/libfabric/archive/refs/tags/v${LIBFABRIC_VERSION}.tar.gz \
 && tar xf v${LIBFABRIC_VERSION}.tar.gz \
 && cd libfabric-${LIBFABRIC_VERSION} \
 && ./autogen.sh \
 && ./configure --prefix=/opt/libfabric \
 && make -j"$(nproc)" \
 && make install

# Build MPICH with Lustre support (matching original config)
COPY mpich_patches.tgz /tmp/build/
RUN wget -q http://www.mpich.org/static/downloads/${MPICH_VERSION}/mpich-${MPICH_VERSION}.tar.gz \
 && tar xf mpich-${MPICH_VERSION}.tar.gz \
 && cd mpich-${MPICH_VERSION} \
 && tar xf /tmp/build/mpich_patches.tgz \
 && patch -p0 < csel.patch \
 && patch -p0 < ch4r_init.patch \
 && PKG_CONFIG_PATH=/opt/libfabric/lib/pkgconfig:/usr/local/lib/pkgconfig \
    CPPFLAGS="-I/usr/local/include -I/opt/libfabric/include" \
    LDFLAGS="-L/usr/local/lib -L/opt/libfabric/lib" \
    LIBS="-llustreapi" \
    ./configure --prefix=/opt/mpich \
      --without-mpe --enable-fortran=all --enable-shared --enable-sharedlibs=gcc \
      --enable-debuginfo --enable-yield=sched_yield --enable-g=mem \
      --with-device=ch4:ofi --with-namepublisher=file \
      --with-shared-memory=sysv --disable-allowport --with-pm=gforker \
      --with-file-system=ufs+lustre+nfs \
      --enable-threads=runtime --enable-fast=O2 --enable-thread-cs=global \
      CC=gcc-12 CXX=g++-12 FC=gfortran-12 FFLAGS=-fallow-argument-mismatch \
 && make -j"$(nproc)" \
 && make install \
 && ldconfig

# Build aws-ofi-rccl
RUN git clone --depth 1 https://github.com/ROCmSoftwarePlatform/aws-ofi-rccl.git \
 && cd aws-ofi-rccl \
 && ./autogen.sh \
 && PKG_CONFIG_PATH=/opt/libfabric/lib/pkgconfig ./configure \
      --prefix=/opt/aws-ofi-rccl \
      --with-mpi=/opt/mpich \
      --with-libfabric=/opt/libfabric \
      --with-hip=/opt/rocm \
      --with-rccl=/opt/rocm \
      CC=gcc-12 CXX=g++-12 \
      CFLAGS="-O2 -D__HIP_PLATFORM_AMD__" \
      CXXFLAGS="-O2 -D__HIP_PLATFORM_AMD__" \
 && make -j"$(nproc)" \
 && make install \
 && ldconfig

# Build OSU microbenchmarks (optional, with ROCm support)
ARG OSU_VERSION="7.3"
ARG ROCM_VERSION
RUN if [ "${ENABLE_OSU}" = "1" ]; then \
      rocm_major=$(echo ${ROCM_VERSION} | sed "s/\\./ /g" | awk '{print $1}') && \
      OSU_CONFIGURE_OPTIONS="--prefix=/opt/osu CC=/opt/mpich/bin/mpicc CXX=/opt/mpich/bin/mpicxx CFLAGS=-O3 --enable-rocm --with-rocm=/opt/rocm" && \
      if [ "${rocm_major}" = "6" ]; then \
        OSU_CONFIGURE_OPTIONS="${OSU_CONFIGURE_OPTIONS} CFLAGS=\"-O3 -D__HIP_PLATFORM_AMD__\" CXXFLAGS=\"-D__HIP_PLATFORM_AMD__\""; \
      fi && \
      wget -q http://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_VERSION}.tar.gz && \
      tar xf osu-micro-benchmarks-${OSU_VERSION}.tar.gz && \
      cd osu-micro-benchmarks-${OSU_VERSION} && \
      eval ./configure ${OSU_CONFIGURE_OPTIONS} && \
      make -j"$(nproc)" && make install ; \
    else \
      mkdir -p /opt/osu ; \
    fi

# ====================== Stage 3: Runtime ======================
FROM ubuntu:${OS_VERSION} AS runtime
ARG ROCM_VERSION
ARG MPI4PY_VERSION
ARG GFX_ARCH
ENV DEBIAN_FRONTEND=noninteractive

# Install minimal runtime dependencies
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    bash ca-certificates wget gnupg lsb-release \
    libnuma1 libgfortran5 libgcc-s1 libstdc++6 \
    libyaml-0-2 keyutils \
    python3 python3-pip python3-venv \
    tzdata \
 && rm -rf /var/lib/apt/lists/*

# Install ROCm runtime
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
 && amdgpu-install -y --usecase=rocm --no-dkms --no-32 \
 && apt-get update -qq \
 && apt-get install -y --no-install-recommends \
      rocm-hip-runtime rocm-hip-libraries \
 && rm -f "/tmp/${ROCM_DEB}" \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /root/.cache

# Copy built libraries and binaries
COPY --from=mpi-builder /usr/local/lib/liblustreapi* /usr/local/lib/
COPY --from=mpi-builder /opt/libfabric /opt/libfabric
COPY --from=mpi-builder /opt/mpich /opt/mpich
COPY --from=mpi-builder /opt/aws-ofi-rccl /opt/aws-ofi-rccl
COPY --from=mpi-builder /opt/osu /opt/osu
RUN ldconfig

# Set up environment
ENV PATH=/opt/mpich/bin:$PATH \
    LD_LIBRARY_PATH=/usr/local/lib:/opt/libfabric/lib:/opt/mpich/lib:/opt/aws-ofi-rccl/lib:$LD_LIBRARY_PATH \
    NCCL_SOCKET_IFNAME=hsn \
    CXI_FORK_SAFE=1 \
    CXI_FORK_SAFE_HP=1 \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    FI_CXI_DISABLE_CQ_HUGETLB=1 \
    ROCM_PATH=/opt/rocm

# Add OSU benchmarks to PATH if built
RUN if [ -d /opt/osu/libexec/osu-micro-benchmarks/mpi/pt2pt ]; then \
      echo 'export PATH=/opt/osu/libexec/osu-micro-benchmarks/mpi/pt2pt:/opt/osu/libexec/osu-micro-benchmarks/mpi/collective:$PATH' >> /etc/profile.d/90-osu.sh ; \
    fi

# Install mpi4py
RUN pip install --break-system-packages mpi4py==${MPI4PY_VERSION}

# GPU arch shim for building on non-GPU hosts (runtime version)
RUN cd /opt/rocm/bin && \
    mv rocm_agent_enumerator rocm_agent_enumerator.orig && \
    echo "echo ${GFX_ARCH}" > rocm_agent_enumerator && \
    chmod +x rocm_agent_enumerator && \
    cd /opt/rocm/lib/llvm/bin && \
    mv amdgpu-arch amdgpu-arch.orig && \
    echo "echo ${GFX_ARCH}" > amdgpu-arch && \
    chmod +x amdgpu-arch

# Singularity environment injection
RUN mkdir -p /.singularity.d/env/ && \
    echo "export NCCL_SOCKET_IFNAME=hsn" >> /.singularity.d/env/91-environment.sh && \
    echo "export CXI_FORK_SAFE=1" >> /.singularity.d/env/91-environment.sh && \
    echo "export CXI_FORK_SAFE_HP=1" >> /.singularity.d/env/91-environment.sh && \
    echo "export HSA_FORCE_FINE_GRAIN_PCIE=1" >> /.singularity.d/env/91-environment.sh && \
    echo "export FI_CXI_DISABLE_CQ_HUGETLB=1" >> /.singularity.d/env/91-environment.sh && \
    echo "export ROCM_PATH=/opt/rocm" >> /.singularity.d/env/91-environment.sh

# Cleanup
RUN rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/locale/* || true

WORKDIR /workspace
LABEL org.opencontainers.image.version=0.0.13 org.opencontainers.image.devmode=true org.opencontainers.image.noscan=true org.opencontainers.image.platform=x86
