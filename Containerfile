FROM ubuntu:25.10

# Build arguments for configurable GCC branch
#ARG BUILD_GCC_BRANCH=amiga13.4
#ARG BUILD_GCC_VERSION=13.4
#ARG BUILD_GCC_BRANCH=amiga16.2
#ARG BUILD_GCC_VERSION=16.2
ARG BUILD_GCC_BRANCH=amiga6
ARG BUILD_GCC_VERSION=6.5.0b

# NDK version - defaults to 3.2 for all GCC versions
ARG NDK_VERSION
ARG BUILD_AMIGA_LTO=1

ENV DEBIAN_FRONTEND=noninteractive

COPY build.sh install_flexcat.sh /root/container-amiga-gcc/

# Build the requested toolchain through the same native entry point used on
# Linux and macOS. Runtime tools such as Vamos and gencrc are installed into
# the versioned prefix as part of the build.
RUN LTO_OPTION=--disable-amiga-lto && \
    if [ "${BUILD_AMIGA_LTO}" = "1" ]; then \
      LTO_OPTION=--enable-amiga-lto; \
    fi && \
    /root/container-amiga-gcc/build.sh \
      --version "${BUILD_GCC_VERSION}:${BUILD_GCC_BRANCH}" \
      --ndk "${NDK_VERSION:-3.2}" \
      --prefix-template 'amiga-{version}' \
      --workdir /root/.amiga-gcc-build \
      "${LTO_OPTION}" \
      --link-default "${BUILD_GCC_VERSION}"

# Clean up
RUN cd / && \
    rm -rf /root/.amiga-gcc-build /root/container-amiga-gcc && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get purge -y \
      libgmp-dev libmpfr-dev libmpc-dev rsync texinfo && \
    apt-get -y autoremove

# Preserve the historical absolute location as well as PATH-based access.
RUN ln -s /opt/amiga/bin/gencrc /bin/gencrc

ENV PATH=/opt/amiga/bin:$PATH

# Add labels for documentation
LABEL gcc.version="${BUILD_GCC_VERSION}"
LABEL gcc.branch="${BUILD_GCC_BRANCH}"
LABEL gcc.amiga_lto="${BUILD_AMIGA_LTO}"
