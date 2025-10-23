# ========================= Common Args =========================
ARG OS_VERSION="24.04"
ARG LIBFABRIC_VERSION="1.18.1"
ARG MPICH_VERSION="3.4.3"
ARG MPI4PY_VERSION="3.1.5"
ARG LUSTRE_TAG="v2_15_0"
ARG ROCM_VERSION="6.4.1"
ARG ENABLE_OSU="1"
ARG GFX_ARCH="gfx90a"

# ====================== Stage 1: Lustre userspace ======================
FROM ubuntu:${OS_VERSION} AS lustre-builder
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies for Lustre userspace
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    build-essential git autoconf automake libtool m4 pkg-config \
    libyaml-dev libkeyutils-dev uuid-dev zlib1g-dev \
    ca-certificates wget curl \
 && rm -rf /var/lib/apt/lists/*

ARG LUSTRE_TAG
WORKDIR /tmp/lustre

# Clone Lustre source (userspace only)
RUN git clone --depth 1 --branch ${LUSTRE_TAG} git://git.whamcloud.com/fs/lustre-release.git .

# Build only userspace libraries (liblustreapi + utils)
RUN ./autogen.sh && \
    ./configure --prefix=/opt/lustre \
      --disable-server --disable-tests \
      --without-ldiskfs --without-zfs \
      --disable-modules && \
    make -C lustre/utils -j"$(nproc)" && make -C lustre/utils install

# ====================== Stage 2: HPC core builder ======================
FROM ubuntu:${OS_VERSION} AS core-builder
ENV DEBIAN_FRONTEND=noninteractive

ARG LIBFABRIC_VERSION
ARG MPICH_VERSION
ARG ENABLE_OSU

# Install build dependencies for MPICH/libfabric/aws-ofi-rccl
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    build-essential gcc-12 g++-12 gfortran-12 \
    git wget curl ca-certificates pkg-config \
    autoconf automake libtool m4 make bison flex \
    libnuma-dev zlib1g-dev libssl-dev libreadline-dev \
    python3 python3-pip python3-dev swig \
    ninja-build \
 && rm -rf /var/lib/apt/lists/*

# Install a modern CMake (only needed during build)
RUN wget -q https://github.com/Kitware/CMake/releases/download/v3.31.7/cmake-3.31.7-linux-x86_64.sh \
 && chmod +x cmake-3.31.7-linux-x86_64.sh \
 && ./cmake-3.31.7-linux-x86_64.sh --skip-license --prefix=/usr \
 && cmake --version

# Copy Lustre userspace from the previous stage (headers + liblustreapi)
COPY --from=lustre-builder /opt/lustre /opt/lustre

WORKDIR /tmp/build

# -------- Build libfabric --------
ARG LIBFABRIC_PREFIX="/opt/libfabric"
RUN wget -q https://github.com/ofiwg/libfabric/archive/refs/tags/v${LIBFABRIC_VERSION}.tar.gz \
 && tar xf v${LIBFABRIC_VERSION}.tar.gz \
 && cd libfabric-${LIBFABRIC_VERSION} \
 && ./autogen.sh && ./configure --prefix=${LIBFABRIC_PREFIX} \
 && make -j"$(nproc)" && make install-strip

# Copy MPICH patch package (from build context)
COPY mpich_patches.tgz /tmp/build/

# -------- Build MPICH (with Lustre ROMIO and patches) --------
ARG MPICH_PREFIX="/opt/mpich"
RUN wget -q http://www.mpich.org/static/downloads/${MPICH_VERSION}/mpich-${MPICH_VERSION}.tar.gz \
 && tar xf mpich-${MPICH_VERSION}.tar.gz && cd mpich-${MPICH_VERSION} \
 # === Apply your patches exactly as before ===
 && tar xf /tmp/build/mpich_patches.tgz \
 && patch -p0 < csel.patch \
 && patch -p0 < ch4r_init.patch \
 # === Configure and build Lustre-aware MPICH ===
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

# ====================== Stage 3: Runtime (Slim) ======================
FROM ubuntu:${OS_VERSION} AS runtime
ENV DEBIAN_FRONTEND=noninteractive

# Minimal runtime dependencies
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    libnuma1 libgfortran5 libgcc-s1 libstdc++6 \
    libyaml-0-2 keyutils \
    python3 python3-pip python3-venv \
    rsync ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/*

# Install minimal ROCm runtime (HIP runtime only)
ARG ROCM_VERSION
RUN wget -q https://repo.radeon.com/amdgpu-install/${ROCM_VERSION}/ubuntu/noble/amdgpu-install_${ROCM_VERSION//./0}-1_all.deb \
 && apt-get -y install ./amdgpu-install_*_all.deb \
 && amdgpu-install -y --usecase=rocm,hip-runtime --no-dkms \
 && apt-get clean && rm -rf /var/lib/apt/lists/* /root/.cache \
 && rm -f /amdgpu-install_*_all.deb

# Copy runtime artifacts only (no headers or dev files)
COPY --from=lustre-builder /opt/lustre/lib/liblustreapi.so* /opt/lustre/lib/
COPY --from=core-builder   /opt/libfabric /opt/libfabric
COPY --from=core-builder   /opt/mpich    /opt/mpich
COPY --from=core-builder   /opt/aws-ofi-rccl /opt/aws-ofi-rccl
COPY --from=core-builder   /opt/osu      /opt/osu

# Set runtime paths
ENV PATH=/opt/mpich/bin:$PATH
ENV LD_LIBRARY_PATH=/opt/lustre/lib:/opt/libfabric/lib:/opt/mpich/lib:/opt/aws-ofi-rccl/lib:$LD_LIBRARY_PATH

# Add OSU benchmark binaries to PATH if present
RUN if [ -d /opt/osu/libexec/osu-micro-benchmarks/mpi/pt2pt ]; then \
      echo 'export PATH=/opt/osu/libexec/osu-micro-benchmarks/mpi/pt2pt:/opt/osu/libexec/osu-micro-benchmarks/mpi/collective:$PATH' >> /etc/profile.d/90-osu.sh ; \
    fi

# Install mpi4py (without pip cache)
ARG MPI4PY_VERSION
RUN pip install --no-cache-dir mpi4py==${MPI4PY_VERSION}

# Optionally remove docs/locales to save space
RUN rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/locale/* || true

# Environment variables (from original version)
ENV NCCL_SOCKET_IFNAME=hsn \
    CXI_FORK_SAFE=1 \
    CXI_FORK_SAFE_HP=1 \
    HSA_FORCE_FINE_GRAIN_PCIE=1 \
    FI_CXI_DISABLE_CQ_HUGETLB=1 \
    ROCM_PATH=/opt/rocm

# GPU architecture shim (useful when building on non-GPU hosts)
ARG GFX_ARCH
RUN printf '#!/bin/sh\necho %s\n' "${GFX_ARCH}" > /usr/local/bin/amdgpu-arch && chmod +x /usr/local/bin/amdgpu-arch && \
    printf '#!/bin/sh\necho %s\n' "${GFX_ARCH}" > /usr/local/bin/rocm_agent_enumerator && chmod +x /usr/local/bin/rocm_agent_enumerator

# Singularity environment scripts (same behavior as before)
RUN mkdir -p /.singularity.d/env/ && \
    echo "export NCCL_SOCKET_IFNAME=hsn"              >> /.singularity.d/env/91-environment.sh && \
    echo "export CXI_FORK_SAFE=1"                     >> /.singularity.d/env/91-environment.sh && \
    echo "export ROCM_PATH=/opt/rocm"                 >> /.singularity.d/env/91-environment.sh && \
    echo "export CXI_FORK_SAFE_HP=1"                  >> /.singularity.d/env/91-environment.sh && \
    echo "export HSA_FORCE_FINE_GRAIN_PCIE=1"         >> /.singularity.d/env/91-environment.sh && \
    echo "export FI_CXI_DISABLE_CQ_HUGETLB=1"         >> /.singularity.d/env/91-environment.sh

WORKDIR /workspace
LABEL org.opencontainers.image.version=0.0.1 org.opencontainers.image.devmode=true org.opencontainers.image.noscan=false org.opencontainers.image.platform=x86
