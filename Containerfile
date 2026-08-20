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

# Install all packages
RUN apt-get -y update && \
    apt-get -y install \
      apt-utils ca-certificates curl file git python3 python3-pip srecord \
      wget autoconf automake bison flex g++ gcc gettext git libgmpxx4ldbl libgmp-dev \
      libmpfr6 libmpfr-dev libmpc3 libmpc-dev libncurses-dev make patch perl rsync \
      texinfo zip

# Build and install lha from source
RUN cd /tmp && \
    git clone --depth 1 https://github.com/jca02266/lha.git && \
    cd lha && \
    autoreconf -vfi && \
    ./configure --prefix=/usr && \
    make -j $(nproc) && \
    make install && \
    cd / && \
    rm -rf /tmp/lha

# Install amitools HEAD with the optional Vamos runtime dependencies.
RUN apt-get -y autoremove && \
    rm -rf /usr/lib/python3.*/EXTERNALLY-MANAGED && \
    pip3 install -U \
      "amitools[vamos] @ git+https://github.com/cnvogelg/amitools.git"

COPY vbcc.diff /root
COPY patches /root/patches
COPY install_additional_sdks.sh /root/install_additional_sdks.sh
COPY install_flexcat.sh /root/install_flexcat.sh

# Install Bebbo's amiga-gcc
RUN NDK=${NDK_VERSION:-3.2} && \
    git config --global pull.rebase false && \
    cd /root && \
    git clone --depth 1 https://github.com/AmigaPorts/m68k-amigaos-gcc amiga-gcc && \
    cd /root/amiga-gcc && \
    if [ "${BUILD_AMIGA_LTO}" = "1" ]; then \
      case "${BUILD_GCC_VERSION}" in \
        6.5.0b|13.4|16.2) ;; \
        *) \
          echo "BUILD_AMIGA_LTO=1 currently requires BUILD_GCC_VERSION=6.5.0b, 13.4, or 16.2" >&2; \
          exit 1; \
          ;; \
      esac; \
    fi && \
    mkdir -p /opt/amiga-${BUILD_GCC_VERSION} && \
    make branch branch=${BUILD_GCC_BRANCH} mod=gcc && \
    make update NDK=${NDK} && \
    patch --forward --batch -p1 -i /root/patches/amiga-gcc-zlib-68060.patch && \
    if [ "${BUILD_AMIGA_LTO}" = "1" ]; then \
      grep -qE '^CONFIG_BINUTILS \+= --enable-plugins' Makefile; \
    fi && \
    make -j $(nproc) all NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) zlib NDK=${NDK} \
      PREFIX=/opt/amiga-${BUILD_GCC_VERSION}/m68k-amigaos \
      PATH=/opt/amiga-${BUILD_GCC_VERSION}/bin:${PATH} \
      AR=/opt/amiga-${BUILD_GCC_VERSION}/bin/m68k-amigaos-ar \
      ARFLAGS=rcs \
      RANLIB=/opt/amiga-${BUILD_GCC_VERSION}/bin/m68k-amigaos-ranlib && \
    LIBSTUBS="/opt/amiga-${BUILD_GCC_VERSION}/m68k-amigaos/lib/libstubs.a" && \
    if ! file "$LIBSTUBS" | grep 'AmigaOS object/library data' >/dev/null; then \
      FIRST_MEMBER="$(/opt/amiga-${BUILD_GCC_VERSION}/bin/m68k-amigaos-ar t "$LIBSTUBS" | sed -n '1p')"; \
      test -n "$FIRST_MEMBER"; \
      /opt/amiga-${BUILD_GCC_VERSION}/bin/m68k-amigaos-ar p "$LIBSTUBS" "$FIRST_MEMBER" \
        | file - | grep 'AmigaOS object/library data' >/dev/null; \
    fi && \
    "/opt/amiga-${BUILD_GCC_VERSION}/bin/m68k-amigaos-nm" \
      "$LIBSTUBS" \
      | grep ' _DOSBase$' >/dev/null

# Install all SDKs. The CD32/CDTV host omits its issuing CA chain, so pin its
# archives before the upstream installer runs. This preserves integrity for
# the HTTP fallback without disabling TLS verification.
RUN NDK=${NDK_VERSION:-3.2} && \
    cd /root/amiga-gcc && \
    for SDK_ARCHIVE_SPEC in \
      "CD32_DeveloperKit.lha:05c53b907ab3ea5874cec9b79b45eb8d760d51b569421d9f556ac2b41124d318" \
      "CDTV_DeveloperKit.lha:5497a8fefca8ade4a509f655eb4a4b3737b9652c16d8cdf934c76fe2dfbe0674"; \
    do \
      SDK_ARCHIVE_NAME=${SDK_ARCHIVE_SPEC%%:*} && \
      SDK_ARCHIVE_SHA256=${SDK_ARCHIVE_SPEC#*:} && \
      SDK_ARCHIVE=download/${SDK_ARCHIVE_NAME} && \
      SDK_ARCHIVE_TMP=${SDK_ARCHIVE}.tmp && \
      rm -f "${SDK_ARCHIVE_TMP}" && \
      (curl -LfsS --connect-timeout 10 \
          "https://www.cd32-allianz.de/downloads/software/${SDK_ARCHIVE_NAME}" \
          -o "${SDK_ARCHIVE_TMP}" || \
        curl -LfsS --connect-timeout 10 --retry 3 \
          "http://www.cd32-allianz.de/downloads/software/${SDK_ARCHIVE_NAME}" \
          -o "${SDK_ARCHIVE_TMP}") && \
      echo "${SDK_ARCHIVE_SHA256}  ${SDK_ARCHIVE_TMP}" \
        | sha256sum --check --strict && \
      mv "${SDK_ARCHIVE_TMP}" "${SDK_ARCHIVE}" || exit 1; \
    done && \
    make -j $(nproc) sdk=filesysbox NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) sdk=sdi NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) sdk=ahi NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) sdk=mhi NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) sdk=camd NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) sdk=cgx NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) sdk=guigfx NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) sdk=mui NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) sdk=p96 NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) sdk=mcc_betterstring NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) sdk=mcc_guigfx NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) sdk=mcc_nlist NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) sdk=mcc_texteditor NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) sdk=mcc_thebar NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) sdk=render NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) sdk=warp3d NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    make -j $(nproc) all-sdk NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION} && \
    /root/install_additional_sdks.sh /opt/amiga-${BUILD_GCC_VERSION} && \
    /root/install_flexcat.sh /opt/amiga-${BUILD_GCC_VERSION}

# Download and fix additional include files
RUN cd /root/amiga-gcc && \
    curl -o newstyle.h https://raw.githubusercontent.com/aros-development-team/AROS/master/compiler/include/devices/newstyle.h && \
    curl -o sana2.h https://raw.githubusercontent.com/aros-development-team/AROS/master/compiler/include/devices/sana2.h && \
    curl -o sana2specialstats.h https://raw.githubusercontent.com/aros-development-team/AROS/master/compiler/include/devices/sana2specialstats.h && \
    curl -o newstyle.diff https://dl.amigadev.com/newstyle.diff && \
    patch --ignore-whitespace < newstyle.diff && \
    mv -fv newstyle.h sana2.h sana2specialstats.h /opt/amiga-${BUILD_GCC_VERSION}/m68k-amigaos/ndk-include/devices/

# Build vlink and vbcc
RUN NDK=${NDK_VERSION:-3.2} && \
    cd /root/amiga-gcc && \
    patch -p1 < ../vbcc.diff && \
    make -j $(nproc) vlink vbcc NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION}

# Install a working VBCC
RUN mkdir -p /tmp/vbcc-targets && \
    curl -o /tmp/vbcc-targets/vbcc_target_m68k-amigaos.lha http://phoenix.owl.de/vbcc/2022-05-22/vbcc_target_m68k-amigaos.lha && \
    cd /tmp/vbcc-targets && \
    lha -x vbcc_target_m68k-amigaos.lha && \
    cd - && \
    mv /tmp/vbcc-targets/vbcc_target_m68k-amigaos/targets /opt/amiga-${BUILD_GCC_VERSION}/m68k-amigaos/vbcc/ && \
    rm -rf /tmp/vbcc-targets

# Install vbcc config files with versioned paths
COPY aos68k aos68km aos68kr /opt/amiga-${BUILD_GCC_VERSION}/bin/
RUN sed -i "s|/opt/amiga/|/opt/amiga-${BUILD_GCC_VERSION}/|g" \
    /opt/amiga-${BUILD_GCC_VERSION}/bin/aos68k \
    /opt/amiga-${BUILD_GCC_VERSION}/bin/aos68km \
    /opt/amiga-${BUILD_GCC_VERSION}/bin/aos68kr

# Build and install mbtaylor1982's gencrc from source
# (the release binary is x86-64 only)
RUN cd /tmp && \
    git clone --depth 1 https://github.com/mbtaylor1982/gencrc.git && \
    cd gencrc && \
    make && \
    install -m 755 gencrc /bin/gencrc && \
    cd / && \
    rm -rf /tmp/gencrc

# Clean up
RUN cd / && \
    rm -rf /root/amiga-gcc && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get purge -y \
      libgmp-dev libmpfr-dev libmpc-dev rsync texinfo && \
    apt-get -y autoremove

# Create symlink from /opt/amiga to versioned directory
RUN ln -s /opt/amiga-${BUILD_GCC_VERSION} /opt/amiga

ENV PATH=/opt/amiga/bin:$PATH

# Add labels for documentation
LABEL gcc.version="${BUILD_GCC_VERSION}"
LABEL gcc.branch="${BUILD_GCC_BRANCH}"
LABEL gcc.amiga_lto="${BUILD_AMIGA_LTO}"
