# ========================= Common Args =========================
ARG OS_VERSION="24.04"
ARG LINUX_KERNEL="6.8.0-31"
ARG LIBFABRIC_VERSION="1.18.1"
ARG MPICH_VERSION="3.4.3"
ARG MPI4PY_VERSION="3.1.5"
ARG ROCM_VERSION="6.4.1"
ARG ENABLE_OSU="1"
ARG GFX_ARCH="gfx90a"
ARG OSU_VERSION="7.3"

# ====================== Stage 1: Builder (完整构建环境) ======================
FROM ubuntu:${OS_VERSION} AS builder
ARG OS_VERSION
ARG LINUX_KERNEL
ARG LIBFABRIC_VERSION
ARG MPICH_VERSION
ARG ROCM_VERSION
ARG GFX_ARCH
ARG OSU_VERSION
ARG ENABLE_OSU
ENV DEBIAN_FRONTEND=noninteractive

# Install all build dependencies
RUN apt-get update -qq && apt-get -y --no-install-recommends install \
    build-essential gcc-12 g++-12 gfortran-12 \
    gnupg gnupg2 ca-certificates gdb wget git curl \
    python3-six python3-setuptools python3-numpy python3-pip python3-scipy python3-venv python3-dev \
    patchelf strace ltrace \
    libcrypt-dev libcurl4-openssl-dev libpython3-dev libreadline-dev libssl-dev \
    sudo autoconf automake bison flex gcovr libtool m4 make openssh-server patch \
    subversion tzdata valgrind vim xsltproc zlib1g-dev ninja-build libnuma-dev swig \
    linux-tools-generic linux-source software-properties-common \
    libkeyutils-dev libnl-genl-3-dev libyaml-dev libmount-dev pkg-config \
    linux-headers-${LINUX_KERNEL}-generic linux-headers-${LINUX_KERNEL} \
    fakeroot devscripts dpkg-dev \
 && rm -rf /var/lib/apt/lists/*

# Install modern CMake
RUN wget -q https://github.com/Kitware/CMake/releases/download/v3.31.7/cmake-3.31.7-linux-x86_64.sh \
 && chmod +x cmake-3.31.7-linux-x86_64.sh \
 && yes | ./cmake-3.31.7-linux-x86_64.sh --prefix=/usr \
 && cmake --version \
 && rm -f cmake-3.31.7-linux-x86_64.sh

# Generate kernel config for Lustre
RUN echo "deb-src http://archive.ubuntu.com/ubuntu noble main restricted" >> /etc/apt/sources.list \
 && apt-get update -qq \
 && cd /tmp \
 && apt-get source linux \
 && cd linux-* \
 && chmod +x ./debian/scripts/misc/annotations \
 && ./debian/scripts/misc/annotations --arch amd64 --flavour generic --export > .config \
 && cp .config /usr/lib/modules/${LINUX_KERNEL}-generic/build/ \
 && cd /tmp && rm -rf linux-*

# Build libfabric
RUN mkdir -p /tmp/build && cd /tmp/build \
 && wget -q https://github.com/ofiwg/libfabric/archive/refs/tags/v${LIBFABRIC_VERSION}.tar.gz \
 && tar xf v${LIBFABRIC_VERSION}.tar.gz \
 && cd libfabric-${LIBFABRIC_VERSION} \
 && ./autogen.sh && ./configure \
 && make -j"$(nproc)" && make install \
 && rm -rf /tmp/build/libfabric-*

# Build Lustre (使用 GitHub 镜像)
RUN mkdir -p /tmp/lustre-build && cd /tmp/lustre-build \
 && for i in 1 2 3; do \
      echo "Cloning Lustre (attempt $i)..." && \
      git clone --depth 1 https://github.com/lustre/lustre-release.git && break || { \
        echo "Clone failed. Retrying in 5s..."; sleep 5; \
      }; \
    done \
 && cd lustre-release \
 && bash autogen.sh \
 && ./configure --disable-server --enable-client \
      --with-linux=/usr/lib/modules/${LINUX_KERNEL}-generic/build \
      --disable-tests \
      CFLAGS=-Wno-error=attribute-warning \
 && make -j"$(nproc)" \
 && make install \
 && ldconfig \
 && cd / && rm -rf /tmp/lustre-build

# Build MPICH with Lustre support
COPY mpich_patches.tgz /tmp/
RUN mkdir -p /tmp/mpich-build && cd /tmp/mpich-build \
 && wget -q http://www.mpich.org/static/downloads/${MPICH_VERSION}/mpich-${MPICH_VERSION}.tar.gz \
 && tar xf mpich-${MPICH_VERSION}.tar.gz \
 && cd mpich-${MPICH_VERSION} \
 && tar xf /tmp/mpich_patches.tgz \
 && patch -p0 < csel.patch \
 && patch -p0 < ch4r_init.patch \
 && ./configure \
      --without-mpe --enable-fortran=all --enable-shared --enable-sharedlibs=gcc \
      --enable-debuginfo --enable-yield=sched_yield --enable-g=mem \
      --with-device=ch4:ofi --with-namepublisher=file \
      --with-shared-memory=sysv --disable-allowport --with-pm=gforker \
      --with-file-system=ufs+lustre+nfs \
      --enable-threads=runtime --enable-fast=O2 --enable-thread-cs=global \
      CC=gcc-12 CXX=g++-12 FC=gfortran-12 FFLAGS=-fallow-argument-mismatch \
 && make -j"$(nproc)" \
 && make install \
 && ldconfig \
 && cd / && rm -rf /tmp/mpich-build

# Install ROCm development packages
RUN apt-get update -qq \
 && ROCM_DEB="amdgpu-install_6.4.60401-1_all.deb" \
 && URL="https://repo.radeon.com/amdgpu-install/${ROCM_VERSION}/ubuntu/noble/${ROCM_DEB}" \
 && wget -q -O "/tmp/${ROCM_DEB}" "${URL}" \
 && dpkg -i "/tmp/${ROCM_DEB}" || true \
 && apt-get -f install -y \
 && dpkg -i "/tmp/${ROCM_DEB}" \
 && mkdir -p /var/cache/apt/archives/partial \
 && amdgpu-install -y --usecase=hiplibsdk,rocm,hip,opencl --no-dkms \
 && rm -f "/tmp/${ROCM_DEB}" \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# GPU arch shim for non-GPU hosts
RUN cd /opt/rocm/bin \
 && mv rocm_agent_enumerator rocm_agent_enumerator.orig \
 && echo "echo ${GFX_ARCH}" > rocm_agent_enumerator \
 && chmod +x rocm_agent_enumerator \
 && cd /opt/rocm/lib/llvm/bin \
 && mv amdgpu-arch amdgpu-arch.orig \
 && echo "echo ${GFX_ARCH}" > amdgpu-arch \
 && chmod +x amdgpu-arch

# Build aws-ofi-rccl
RUN cd /tmp \
 && rocm_major=$(echo ${ROCM_VERSION} | sed "s/\\./ /g" | awk '{print $1}') \
 && git clone --depth 1 https://github.com/ROCmSoftwarePlatform/aws-ofi-rccl.git \
 && cd aws-ofi-rccl \
 && ./autogen.sh \
 && RCCL_OPTS="--prefix=/usr --with-mpi=/usr --with-libfabric=/usr --with-hip=/opt/rocm --with-rccl=/opt/rocm CC=gcc-12 CXX=g++-12" \
 && if [ "${rocm_major}" = "6" ]; then \
      RCCL_OPTS="${RCCL_OPTS} CFLAGS=-D__HIP_PLATFORM_AMD__ CXXFLAGS=-D__HIP_PLATFORM_AMD__"; \
    fi \
 && eval ./configure ${RCCL_OPTS} \
 && make -j"$(nproc)" \
 && make install \
 && ldconfig \
 && cd /tmp && rm -rf aws-ofi-rccl

# Build OSU microbenchmarks
RUN if [ "${ENABLE_OSU}" = "1" ]; then \
      cd /tmp && \
      rocm_major=$(echo ${ROCM_VERSION} | sed "s/\\./ /g" | awk '{print $1}') && \
      wget -q http://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_VERSION}.tar.gz && \
      tar xf osu-micro-benchmarks-${OSU_VERSION}.tar.gz && \
      cd osu-micro-benchmarks-${OSU_VERSION} && \
      OSU_OPTS="--prefix=/usr/local CC=mpicc CXX=mpicxx CFLAGS=-O3 --enable-rocm --with-rocm=/opt/rocm" && \
      if [ "${rocm_major}" = "6" ]; then \
        OSU_OPTS="${OSU_OPTS} CXXFLAGS=-D__HIP_PLATFORM_AMD__"; \
      fi && \
      eval ./configure ${OSU_OPTS} && \
      make -j"$(nproc)" && \
      make install && \
      cd /tmp && rm -rf osu-micro-benchmarks-*; \
    fi

# Check installed files for debugging
RUN echo "=== Checking Lustre files ===" \
 && find /usr -name "*lustre*" -o -name "liblustreapi*" 2>/dev/null | head -20 || true

# ====================== Stage 2: Runtime (精简运行时) ======================
FROM ubuntu:${OS_VERSION} AS runtime
ARG ROCM_VERSION
ARG MPI4PY_VERSION
ARG GFX_ARCH
ARG ENABLE_OSU
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
RUN apt-get update -qq \
 && ROCM_DEB="amdgpu-install_6.4.60401-1_all.deb" \
 && URL="https://repo.radeon.com/amdgpu-install/${ROCM_VERSION}/ubuntu/noble/${ROCM_DEB}" \
 && wget -q -O "/tmp/${ROCM_DEB}" "${URL}" \
 && dpkg -i "/tmp/${ROCM_DEB}" || true \
 && apt-get -f install -y \
 && dpkg -i "/tmp/${ROCM_DEB}" \
 && mkdir -p /var/cache/apt/archives/partial \
 && amdgpu-install -y --usecase=rocm --no-dkms --no-32 \
 && apt-get update -qq \
 && apt-get install -y --no-install-recommends rocm-hip-runtime rocm-hip-libraries \
 && rm -f "/tmp/${ROCM_DEB}" \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /root/.cache

# Copy runtime files from builder
COPY --from=builder /usr/lib/liblustreapi* /usr/lib/
COPY --from=builder /usr/lib/libfabric* /usr/lib/
COPY --from=builder /usr/lib/libmpi* /usr/lib/
COPY --from=builder /usr/lib/libmpich* /usr/lib/
COPY --from=builder /usr/lib/libmpl* /usr/lib/
COPY --from=builder /usr/lib/libopa* /usr/lib/
COPY --from=builder /usr/lib/librccl_net.so /usr/lib/
COPY --from=builder /usr/bin/mpi* /usr/bin/
COPY --from=builder /usr/bin/hydra* /usr/bin/
COPY --from=builder /usr/bin/parkill /usr/bin/
COPY --from=builder /usr/local/libexec/osu-micro-benchmarks /usr/local/libexec/osu-micro-benchmarks

RUN ldconfig

# Install mpi4py
RUN pip install --break-system-packages mpi4py==${MPI4PY_VERSION}

# GPU arch shim
RUN cd /opt/rocm/bin \
 && mv rocm_agent_enumerator rocm_agent_enumerator.orig \
 && echo "echo ${GFX_ARCH}" > rocm_agent_enumerator \
 && chmod +x rocm_agent_enumerator \
 && cd /opt/rocm/lib/llvm/bin \
 && mv amdgpu-arch amdgpu-arch.orig \
 && echo "echo ${GFX_ARCH}" > amdgpu-arch \
 && chmod +x amdgpu-arch

# Set up environment
ENV PATH="/usr/local/libexec/osu-micro-benchmarks/mpi/collective:/usr/local/libexec/osu-micro-benchmarks/mpi/one-sided:/usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt:/usr/local/libexec/osu-micro-benchmarks/mpi/startup:$PATH" \
    NCCL_SOCKET_IFNAME=hsn \
    CXI_FORK_SAFE=1 \
    CXI_FORK_SAFE_HP=1 \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    FI_CXI_DISABLE_CQ_HUGETLB=1 \
    ROCM_PATH=/opt/rocm

# Singularity environment injection
RUN mkdir -p /.singularity.d/env/ \
 && echo "export NCCL_SOCKET_IFNAME=hsn" >> /.singularity.d/env/91-environment.sh \
 && echo "export CXI_FORK_SAFE=1" >> /.singularity.d/env/91-environment.sh \
 && echo "export CXI_FORK_SAFE_HP=1" >> /.singularity.d/env/91-environment.sh \
 && echo "export HSA_FORCE_FINE_GRAIN_PCIE=1" >> /.singularity.d/env/91-environment.sh \
 && echo "export FI_CXI_DISABLE_CQ_HUGETLB=1" >> /.singularity.d/env/91-environment.sh \
 && echo "export ROCM_PATH=/opt/rocm" >> /.singularity.d/env/91-environment.sh

# Cleanup
RUN rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/locale/* || true

# Debug: Check what was copied
RUN echo "=== Runtime libraries check ===" \
 && ls -lh /usr/lib/liblustreapi* || echo "No Lustre libs" \
 && ls -lh /usr/lib/libmpi* || echo "No MPI libs" \
 && which mpicc || echo "No mpicc" \
 && which mpirun || echo "No mpirun"

WORKDIR /workspace
LABEL org.opencontainers.image.version=0.0.18 org.opencontainers.image.devmode=true org.opencontainers.image.noscan=true org.opencontainers.image.platform=x86
