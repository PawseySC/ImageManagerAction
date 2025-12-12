# ========================= Common Args =========================
ARG OS_VERSION="24.04"
ARG LINUX_KERNEL="6.8.0-31"
ARG LIBFABRIC_VERSION="1.18.1"
ARG MPICH_VERSION="3.4.3"
ARG MPI4PY_VERSION="3.1.5"
ARG ENABLE_OSU="1"
ARG CUDA_VERSION="13-0"
ARG OSU_VERSION="7.3"
ARG IMAGE_NAME="nvidia/cuda"

# ====================== Stage 1: Builder (full build environment) ======================
FROM ubuntu:${OS_VERSION} AS builder

ARG OS_VERSION
ARG LINUX_KERNEL
ARG LIBFABRIC_VERSION
ARG MPICH_VERSION
ARG CUDA_VERSION
ARG OSU_VERSION
ARG ENABLE_OSU
ENV DEBIAN_FRONTEND=noninteractive

# Build toolchain & headers
RUN apt-get update -qq && apt-get -y --no-install-recommends install \
    build-essential \
    libc6-dev \                      
    gcc-12 g++-12 gfortran-12 \
    gnupg gnupg2 ca-certificates gdb wget git curl \
    python3-six python3-setuptools python3-numpy python3-pip python3-scipy python3-venv python3-dev \
    patchelf strace ltrace \
    libcrypt-dev libcurl4-openssl-dev libpython3-dev libreadline-dev libssl-dev \
    sudo autoconf automake bison flex gcovr libtool m4 make openssh-server patch \
    subversion tzdata valgrind vim xsltproc zlib1g-dev ninja-build libnuma-dev swig \
    linux-tools-generic linux-source software-properties-common \
    libkeyutils-dev libnl-genl-3-dev libyaml-dev libmount-dev pkg-config \
    libhwloc-dev hwloc \
    linux-headers-${LINUX_KERNEL}-generic linux-headers-${LINUX_KERNEL} \
    fakeroot devscripts dpkg-dev \
 && rm -rf /var/lib/apt/lists/*

# Install CUDA packages from NVIDIA repository
RUN wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/sbsa/cuda-keyring_1.1-1_all.deb \
 && dpkg -i cuda-keyring_1.1-1_all.deb \
 && rm cuda-keyring_1.1-1_all.deb \
 && apt-get update -qq \
 && apt-get install -y --no-install-recommends \
    cuda-cudart-dev-${CUDA_VERSION} \
    cuda-nvcc-${CUDA_VERSION} \
    cuda-crt-${CUDA_VERSION} \
    cuda-cudart-${CUDA_VERSION} \
    cuda-driver-dev-${CUDA_VERSION} \
    cuda-libraries-dev-${CUDA_VERSION} \
    libcudnn9-dev-cuda-12 \
    libnccl2 libnccl-dev \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s /usr/local/cuda-13.0 /usr/local/cuda

ENV PATH="/usr/local/cuda/bin:${PATH}"
ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH}"
ENV CUDA_HOME="/usr/local/cuda"

# Modern CMake
RUN wget -q https://github.com/Kitware/CMake/releases/download/v3.31.7/cmake-3.31.7-linux-aarch64.sh \
 && chmod +x cmake-3.31.7-linux-aarch64.sh \
 && ./cmake-3.31.7-linux-aarch64.sh --skip-license --prefix=/usr --include-subdir \
 && ln -sf /usr/cmake-3.31.7-linux-aarch64/bin/cmake /usr/bin/cmake \
 && ln -sf /usr/cmake-3.31.7-linux-aarch64/bin/ctest /usr/bin/ctest \
 && ln -sf /usr/cmake-3.31.7-linux-aarch64/bin/cpack /usr/bin/cpack \
 && cmake --version \
 && rm -f cmake-3.31.7-linux-aarch64.sh

# Kernel config for Lustre
RUN echo "deb-src http://archive.ubuntu.com/ubuntu noble main restricted" >> /etc/apt/sources.list \
 && apt-get update -qq \
 && cd /tmp \
 && apt-get source linux \
 && cd linux-* \
 && chmod +x ./debian/scripts/misc/annotations \
 && ./debian/scripts/misc/annotations --arch arm64 --flavour generic --export > .config \
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

# Build Lustre client
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
ARG MPICH_CONFIGURE_OPTIONS="--prefix=/usr --without-mpe --enable-fortran=all --enable-shared --enable-sharedlibs=gcc \
--enable-debuginfo --enable-yield=sched_yield --enable-g=mem \
--with-device=ch4:ofi --with-namepublisher=file \
--with-shared-memory=sysv --disable-allowport --with-pm=gforker \
--with-file-system=ufs+lustre+nfs \
--enable-threads=runtime --enable-fast=O2 --enable-thread-cs=global \
CC=gcc-12 CXX=g++-12 FC=gfortran-12 FFLAGS=-fallow-argument-mismatch"  # <<< CHANGED: 加 prefix=/usr
COPY mpich_patches.tgz /tmp/
RUN echo "Building MPICH..." \
 && mkdir -p /tmp/mpich-build && cd /tmp/mpich-build \
 && wget -q http://www.mpich.org/static/downloads/${MPICH_VERSION}/mpich-${MPICH_VERSION}.tar.gz \
 && tar xf mpich-${MPICH_VERSION}.tar.gz \
 && cd mpich-${MPICH_VERSION} \
 && tar xf /tmp/mpich_patches.tgz \
 && patch -p0 < csel.patch \
 && patch -p0 < ch4r_init.patch \
 && ./configure ${MPICH_CONFIGURE_OPTIONS} \
 && make -j"$(nproc)" \
 && make install \
 && ldconfig \
 && cd / && rm -rf /tmp/mpich-build \
 && echo "Finished building MPICH"

# Build aws-ofi-nccl (CUDA NCCL plugin for libfabric)
# RUN echo "Build aws-ofi-nccl" \
#  && cd /tmp \
#  && git clone --depth 1 https://github.com/aws/aws-ofi-nccl.git \
#  && cd aws-ofi-nccl \
#  && ./autogen.sh \
#  && CC=gcc-12 CXX=g++-12 \
#     ./configure --prefix=/usr \
#                 --with-mpi=/usr \
#                 --with-libfabric=/usr \
#                 --with-cuda=/usr/local/cuda \
#                 LDFLAGS="-L/usr/local/cuda/lib64 -L/usr/local/cuda/lib64/stubs" \
#  && make -j"$(nproc)" \
#  && make install \
#  && ldconfig \
#  && cd /tmp && rm -rf aws-ofi-nccl \
#  && echo "Done"

# Build OSU microbenchmarks
ARG OSU_CONFIGURE_OPTIONS="--prefix=/usr/local CC=mpicc CXX=mpicxx CFLAGS=-O3 --enable-cuda --with-cuda=/usr/local/cuda"
RUN if [ "${ENABLE_OSU}" = "1" ]; then \
      echo "Building OSU..." && \
      cd /tmp && \
      wget -q http://mvapich.cse.ohio-state.edu/download/mvapich/osu-micro-benchmarks-${OSU_VERSION}.tar.gz && \
      tar xf osu-micro-benchmarks-${OSU_VERSION}.tar.gz && \
      cd osu-micro-benchmarks-${OSU_VERSION} && \
      ./configure ${OSU_CONFIGURE_OPTIONS} && \
      make -j"$(nproc)" && \
      make install && \
      cd /tmp && rm -rf osu-micro-benchmarks-* && \
      echo "Done"; \
    fi

# Check installed files for debugging
RUN echo "=== Checking Lustre files ===" \
 && find /usr -name "*lustre*" -o -name "liblustreapi*" 2>/dev/null | head -20 || true

# ====================== Stage 2: Runtime (minimal runtime environment) ======================
FROM ${IMAGE_NAME}:13.0.2-runtime-ubuntu${OS_VERSION} AS runtime

ARG MPI4PY_VERSION
ARG CUDA_VERSION
ARG ENABLE_OSU
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    bash ca-certificates wget gnupg lsb-release \
    libnuma1 libgfortran5 libgcc-s1 libstdc++6 \
    libyaml-0-2 keyutils \
    python3 python3-pip python3-venv \
    tzdata \
 && rm -rf /var/lib/apt/lists/*

# Copy runtime files from builder
# libfabric and lustre install to /usr/local/lib by default
# mpich installs to /usr (--prefix=/usr)
COPY --from=builder /usr/local/lib/liblustreapi* /usr/local/lib/
COPY --from=builder /usr/local/lib/libfabric* /usr/local/lib/
COPY --from=builder /usr/lib/libmpi* /usr/lib/
COPY --from=builder /usr/lib/libmpich* /usr/lib/
COPY --from=builder /usr/lib/libmpl* /usr/lib/
COPY --from=builder /usr/lib/libopa* /usr/lib/
COPY --from=builder /usr/bin/mpi* /usr/bin/
COPY --from=builder /usr/bin/hydra* /usr/bin/
COPY --from=builder /usr/bin/parkill /usr/bin/
COPY --from=builder /usr/local/libexec/osu-micro-benchmarks /usr/local/libexec/osu-micro-benchmarks

RUN ldconfig

RUN pip install --break-system-packages mpi4py==${MPI4PY_VERSION}

ENV PATH="/usr/local/libexec/osu-micro-benchmarks/mpi/collective:/usr/local/libexec/osu-micro-benchmarks/mpi/one-sided:/usr/local/libexec/osu-micro-benchmarks/mpi/pt2pt:/usr/local/libexec/osu-micro-benchmarks/mpi/startup:$PATH" \
    NCCL_SOCKET_IFNAME=hsn \
    CXI_FORK_SAFE=1 \
    CXI_FORK_SAFE_HP=1 \
    FI_CXI_DISABLE_CQ_HUGETLB=1 \
    CUDA_PATH=/usr/local/cuda \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/lib64/stubs:${LD_LIBRARY_PATH}

# Singularity environment injection
RUN mkdir -p /.singularity.d/env/ \
 && echo "export NCCL_SOCKET_IFNAME=hsn" >> /.singularity.d/env/91-environment.sh \
 && echo "export CXI_FORK_SAFE=1" >> /.singularity.d/env/91-environment.sh \
 && echo "export CXI_FORK_SAFE_HP=1" >> /.singularity.d/env/91-environment.sh \
 && echo "export FI_CXI_DISABLE_CQ_HUGETLB=1" >> /.singularity.d/env/91-environment.sh \
 && echo "export CUDA_PATH=/usr/local/cuda" >> /.singularity.d/env/91-environment.sh \
 && echo "export LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/lib64/stubs:\${LD_LIBRARY_PATH}" >> /.singularity.d/env/91-environment.sh

RUN rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/locale/* || true

RUN echo "=== Runtime libraries check ===" \
 && ls -lh /usr/lib/liblustreapi* || echo "No Lustre libs" \
 && ls -lh /usr/lib/libmpi* || echo "No MPI libs" \
 && which mpicc || echo "No mpicc" \
 && which mpirun || echo "No mpirun"

WORKDIR /workspace
LABEL org.opencontainers.image.version=0.0.1 org.opencontainers.image.devmode=true org.opencontainers.image.noscan=true org.opencontainers.image.platform=arm
