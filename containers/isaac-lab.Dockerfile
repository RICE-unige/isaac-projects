ARG ISAAC_IMAGE=nvcr.io/nvidia/isaac-sim:5.1.0
FROM ${ISAAC_IMAGE}

ARG ISAAC_IMAGE
ARG ISAACLAB_PATH=external/IsaacLab
ARG ISAACLAB_REF=unknown
ARG ISAACLAB_FRAMEWORKS=rsl_rl
ARG ISAACLAB_CHECKOUT_REV=unknown
ARG ISAACLAB_DOCKERFILE_HASH=unknown

SHELL ["/bin/bash", "-lc"]
USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends git ca-certificates cmake build-essential && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/isaac-projects
COPY . /workspace/isaac-projects

RUN test -f "/workspace/isaac-projects/${ISAACLAB_PATH}/isaaclab.sh" && \
    test -d /isaac-sim && \
    rm -rf "/workspace/isaac-projects/${ISAACLAB_PATH}/_isaac_sim" && \
    ln -s /isaac-sim "/workspace/isaac-projects/${ISAACLAB_PATH}/_isaac_sim" && \
    /isaac-sim/python.sh -m pip install --no-build-isolation --editable "/workspace/isaac-projects/${ISAACLAB_PATH}/source/isaaclab" && \
    cd "/workspace/isaac-projects/${ISAACLAB_PATH}" && \
    PIP_NO_BUILD_ISOLATION=1 TERM=xterm ./isaaclab.sh --install "${ISAACLAB_FRAMEWORKS}"

LABEL rice.isaaclab.path="${ISAACLAB_PATH}" \
      rice.isaaclab.ref="${ISAACLAB_REF}" \
      rice.isaaclab.frameworks="${ISAACLAB_FRAMEWORKS}" \
      rice.isaaclab.checkout_rev="${ISAACLAB_CHECKOUT_REV}" \
      rice.isaaclab.dockerfile_hash="${ISAACLAB_DOCKERFILE_HASH}" \
      rice.isaaclab.base_image="${ISAAC_IMAGE}"

WORKDIR /workspace/isaac-projects
