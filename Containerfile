FROM ubuntu:26.04

# Build arguments for configurable GCC branch
#ARG BUILD_GCC_BRANCH=amiga13.4
#ARG BUILD_GCC_VERSION=13.4
ARG BUILD_GCC_BRANCH=amiga16.2
ARG BUILD_GCC_VERSION=16.2

# A release tag of AmigaPorts/m68k-amigaos-gcc, such as v16.2-rc21: every
# module is built at its m68k-amigaos-gcc-TAG tag, and BUILD_GCC_BRANCH is
# ignored.  m68k-amigaos only.
ARG BUILD_RELEASE_TAG=""

# ppc-amigaos: the AmigaPorts/binutils-gdb ref, such as
# m68k-amigaos-gcc-v16.2-rc21 for a release, instead of build.sh's default.
ARG BUILD_BINUTILS_REF=""

# NDK version - defaults to 3.2 for all GCC versions
ARG NDK_VERSION

# m68k-amigaos, or ppc-amigaos for AmigaOS 4. For ppc-amigaos,
# BUILD_GCC_BRANCH is the AmigaPorts/gcc ref and the prefix is
# /opt/amiga-ppc-VERSION, linked from /opt/amiga-ppc.
ARG BUILD_TARGET=m68k-amigaos

ENV DEBIAN_FRONTEND=noninteractive

COPY build.sh ppc-amigaos.sh install_flexcat.sh /root/container-amiga-gcc/

# Build the requested toolchain through the same native entry point used on
# Linux and macOS. Runtime tools such as Vamos and gencrc are installed into
# the versioned prefix as part of the build.
RUN if [ "${BUILD_TARGET}" = ppc-amigaos ]; then \
      prefix_template='amiga-ppc-{version}'; \
    else \
      prefix_template='amiga-{version}'; \
    fi && \
    /root/container-amiga-gcc/build.sh \
      --target "${BUILD_TARGET}" \
      --version "${BUILD_GCC_VERSION}:${BUILD_GCC_BRANCH}" \
      ${BUILD_RELEASE_TAG:+--release-tag "${BUILD_RELEASE_TAG}"} \
      ${BUILD_BINUTILS_REF:+--binutils-ref "${BUILD_BINUTILS_REF}"} \
      --ndk "${NDK_VERSION:-3.2}" \
      --prefix-template "${prefix_template}" \
      --workdir /root/.amiga-gcc-build \
      --link-default "${BUILD_GCC_VERSION}" && \
    cd / && \
    rm -rf /root/.amiga-gcc-build /root/container-amiga-gcc && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get purge -y \
      libgmp-dev libmpfr-dev libmpc-dev rsync texinfo && \
    apt-get -y autoremove

# Host tools that projects built in this image use alongside the cross
# compiler, such as CMake for native helpers (the L-Packer executable packer
# in A4091 and xSysInfo). The toolchain build itself does not need them.
RUN apt-get update && \
    apt-get install -y --no-install-recommends cmake && \
    rm -rf /var/lib/apt/lists/*

# Preserve the historical absolute location as well as PATH-based access.
RUN if [ -x /opt/amiga/bin/gencrc ]; then \
      ln -s /opt/amiga/bin/gencrc /bin/gencrc; \
    fi

# Only one of the two exists in an image.
ENV PATH=/opt/amiga/bin:/opt/amiga-ppc/bin:$PATH

# Add labels for documentation
LABEL gcc.target="${BUILD_TARGET}"
LABEL gcc.version="${BUILD_GCC_VERSION}"
LABEL gcc.branch="${BUILD_GCC_BRANCH}"
LABEL gcc.release_tag="${BUILD_RELEASE_TAG}"
LABEL gcc.binutils_ref="${BUILD_BINUTILS_REF}"
LABEL gcc.amiga_lto="1"
