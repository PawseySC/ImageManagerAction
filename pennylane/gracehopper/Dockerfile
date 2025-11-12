########################################################
# PennyLane Docker Image for Grace Hopper supercomputer

#docker buildx build --platform linux/arm64 -f pennylane-gh.dockerfile --target wheel-out --build-arg CUDA_VER=12.8.1 --build-arg LIGHTNING_VERSION=v0.43.0 --build-arg PY_VER=3.11 --build-arg PENNYLANE_VERSION=0.43.0 --output type=local,dest=./wheelhouse .
# or download from quay.io/pawsey/pennylane-gracehopper:0.0.1

########################################################

# Define global build defaults
ARG PENNYLANE_VERSION=master
ARG PYTHON_VERSION=3.11
ARG CUDA_VER=12.8.1
ARG LIGHTNING_VERSION=master

# Create basic runtime environment base on Ubuntu 22.04 (jammy)
# Create and activate runtime virtual environment
FROM ubuntu:jammy AS base-runtime
ARG PYTHON_VERSION
ARG CUDA_ARCH=HOPPER90
ARG CUDA_VER
ARG DEBIAN_FRONTEND=noninteractive
ARG GCC_VERSION=11
ARG LIGHTNING_VERSION
ARG PENNYLANE_VERSION
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
    apt-utils \
    software-properties-common \
    gnupg \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update \
    && apt-get install --no-install-recommends -y \
    ca-certificates \
    git \
    libgomp1 \
    python${PYTHON_VERSION} \
    python3-pip \
    python${PYTHON_VERSION}-venv \
    tzdata \
    wget \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
ENV VIRTUAL_ENV=/opt/venv
RUN python${PYTHON_VERSION} -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# Create basic build environment with build tools and compilers
FROM base-runtime AS base-build
ARG PYTHON_VERSION
ARG GCC_VERSION=11
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
    build-essential \
    ccache \
    cmake \
    curl \
    ninja-build \
    python${PYTHON_VERSION}-dev \
    gcc-${GCC_VERSION} g++-${GCC_VERSION} cpp-${GCC_VERSION} \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
RUN update-alternatives \
    --install /usr/bin/gcc gcc /usr/bin/gcc-${GCC_VERSION} 100 \
    --slave /usr/bin/g++ g++ /usr/bin/g++-${GCC_VERSION} \
    --slave /usr/bin/gcov gcov /usr/bin/gcov-${GCC_VERSION}
RUN /usr/sbin/update-ccache-symlinks
RUN mkdir /opt/ccache
RUN ccache --set-config=cache_dir=/opt/ccache

# Create and activate build virtual environment
# Install Lightning dev requirements
FROM base-build AS base-build-python
ARG LIGHTNING_VERSION
ARG PYTHON_VERSION
WORKDIR /opt/pennylane-lightning
ENV VIRTUAL_ENV=/opt/venv-build
RUN python${PYTHON_VERSION} -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
RUN rm -rf tmp && git clone --depth 1 --branch ${LIGHTNING_VERSION} https://github.com/PennyLaneAI/pennylane-lightning.git tmp\
    && mv tmp/* /opt/pennylane-lightning && rm -rf tmp
RUN pip install --no-cache-dir build cmake ninja toml wheel setuptools>=75.8.1

# Download Lightning release and build lightning-qubit backend
FROM base-build-python AS build-wheel-lightning-qubit
WORKDIR /opt/pennylane-lightning
RUN pip uninstall -y pennylane-lightning
RUN python scripts/configure_pyproject_toml.py || true
RUN python -m build --wheel

# Install lightning-qubit backend
FROM base-runtime AS wheel-lightning-qubit
COPY --from=build-wheel-lightning-qubit /opt/pennylane-lightning/dist/ /
RUN pip install --force-reinstall --no-cache-dir pennylane_lightning*.whl && rm pennylane_lightning*.whl
RUN pip install --no-cache-dir git+https://github.com/PennyLaneAI/pennylane.git@${PENNYLANE_VERSION}

# Use NVIDIA CUDA devel image with CUDA toolkit pre-installed
FROM nvidia/cuda:${CUDA_VER}-devel-ubuntu22.04 AS base-build-cuda
ARG CUDA_VER
ARG PYTHON_VERSION
ARG GCC_VERSION=11
ARG LIGHTNING_VERSION=master
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
    software-properties-common \
    gnupg \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update \
    && apt-get install --no-install-recommends -y \
    build-essential \
    ccache \
    cmake \
    curl \
    git \
    ninja-build \
    python${PYTHON_VERSION} \
    python${PYTHON_VERSION}-dev \
    python${PYTHON_VERSION}-venv \
    python3-pip \
    wget \
    gcc-${GCC_VERSION} g++-${GCC_VERSION} cpp-${GCC_VERSION} \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
RUN update-alternatives \
    --install /usr/bin/gcc gcc /usr/bin/gcc-${GCC_VERSION} 100 \
    --slave /usr/bin/g++ g++ /usr/bin/g++-${GCC_VERSION} \
    --slave /usr/bin/gcov gcov /usr/bin/gcov-${GCC_VERSION}
ENV VIRTUAL_ENV=/opt/venv-build
RUN python${PYTHON_VERSION} -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
WORKDIR /opt/pennylane-lightning
RUN rm -rf tmp && git clone --depth 1 --branch ${LIGHTNING_VERSION} https://github.com/PennyLaneAI/pennylane-lightning.git tmp\
    && mv tmp/* /opt/pennylane-lightning && rm -rf tmp
RUN pip install --no-cache-dir build cmake ninja toml wheel setuptools>=75.8.1
ENV PATH=/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}

# Download and build Lightning-GPU release
FROM base-build-cuda AS build-wheel-lightning-gpu
WORKDIR /opt/pennylane-lightning
ENV PL_BACKEND=lightning_gpu
RUN pip install --no-cache-dir wheel custatevec-cu12
RUN pip uninstall -y pennylane-lightning
RUN python scripts/configure_pyproject_toml.py || true
RUN CUQUANTUM_SDK=$(python -c "import site; print( f'{site.getsitepackages()[0]}/cuquantum/lib')") python -m build --wheel


# Install python3 and setup runtime virtual env in CUDA-12-runtime image (includes CUDA runtime and math libraries)
# Install lightning-gpu CUDA backend
FROM nvidia/cuda:${CUDA_VER}-runtime-ubuntu22.04 AS wheel-lightning-gpu
ARG CUDA_VER
ARG PENNYLANE_VERSION
ARG PYTHON_VERSION
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
    software-properties-common \
    gnupg \
    && add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update \
    && apt-get install --no-install-recommends -y \
    git \
    libgomp1 \
    python${PYTHON_VERSION} \
    python3-pip \
    python${PYTHON_VERSION}-venv \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
ENV VIRTUAL_ENV=/opt/venv
RUN python${PYTHON_VERSION} -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
RUN pip install --no-cache-dir custatevec-cu12
ENV LD_LIBRARY_PATH="$VIRTUAL_ENV/lib/python${PYTHON_VERSION}/site-packages/cuquantum/lib:$LD_LIBRARY_PATH"
COPY --from=build-wheel-lightning-gpu /opt/pennylane-lightning/dist/ /
COPY --from=build-wheel-lightning-qubit /opt/pennylane-lightning/dist/ /
RUN pip install --no-cache-dir --force-reinstall pennylane_lightning*.whl
RUN pip install --no-cache-dir git+https://github.com/PennyLaneAI/pennylane.git@${PENNYLANE_VERSION}
RUN pip install --no-cache-dir matplotlib jupyterlab
LABEL org.opencontainers.image.version=0.0.3 org.opencontainers.image.devmode=true org.opencontainers.image.noscan=false org.opencontainers.image.platform=arm
