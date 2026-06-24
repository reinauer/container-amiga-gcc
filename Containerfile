FROM ubuntu:25.10

# Build arguments for configurable GCC branch
#ARG BUILD_GCC_BRANCH=amiga13.4
#ARG BUILD_GCC_VERSION=13.4
#ARG BUILD_GCC_BRANCH=amiga16.1
#ARG BUILD_GCC_VERSION=16.1
ARG BUILD_GCC_BRANCH=amiga6
ARG BUILD_GCC_VERSION=6.5.0b

# NDK version - defaults to 3.9 for GCC 15.2, 3.2 for others
ARG NDK_VERSION
ARG BUILD_AMIGA_LTO=0
ARG BUILD_BEBBO_AMIGA6_PATCHES=0

ENV DEBIAN_FRONTEND=noninteractive

# Install all packages
RUN apt-get -y update && \
    apt-get -y install \
      apt-utils curl file git python3 python3-pip srecord \
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

# Install amitools.
RUN apt-get -y autoremove && \
    rm -rf /usr/lib/python3.*/EXTERNALLY-MANAGED && \
    pip3 install -U git+https://github.com/cnvogelg/amitools.git

COPY vbcc.diff /root
COPY patches /root/patches

# Install Bebbo's amiga-gcc
RUN NDK=${NDK_VERSION:-$([ "${BUILD_GCC_VERSION}" = "15.2" ] && echo "3.9" || echo "3.2")} && \
    git config --global pull.rebase false && \
    cd /root && \
    git clone --depth 1 https://github.com/AmigaPorts/m68k-amigaos-gcc amiga-gcc && \
    cd /root/amiga-gcc && \
    if [ "${BUILD_AMIGA_LTO}" = "1" ]; then \
      case "${BUILD_GCC_VERSION}" in \
        13.4|16.1) ;; \
        *) \
          echo "BUILD_AMIGA_LTO=1 currently requires BUILD_GCC_VERSION=13.4 or 16.1" >&2; \
          exit 1; \
          ;; \
      esac; \
    fi && \
    if [ "${BUILD_AMIGA_LTO}" = "1" ] && [ "${BUILD_BEBBO_AMIGA6_PATCHES}" = "1" ]; then \
      echo "BUILD_AMIGA_LTO=1 and BUILD_BEBBO_AMIGA6_PATCHES=1 cannot be combined" >&2; \
      exit 1; \
    fi && \
    if [ "${BUILD_BEBBO_AMIGA6_PATCHES}" = "1" ] && [ "${BUILD_GCC_BRANCH}" != "amiga6" ]; then \
      echo "BUILD_BEBBO_AMIGA6_PATCHES=1 requires BUILD_GCC_BRANCH=amiga6" >&2; \
      exit 1; \
    fi && \
    sed -i -r 's#\S+/gcc#https://github.com/AmigaPorts/gcc#g' default-repos && \
    mkdir -p /opt/amiga-${BUILD_GCC_VERSION} && \
    make branch branch=${BUILD_GCC_BRANCH} mod=gcc && \
    make update NDK=${NDK} && \
    cmpxf2=projects/libnix/sources/math/math/__cmpxf2.c && \
    if [ -f "$cmpxf2" ] && ! grep -q 'CODEX_GCC15_LIBNIX_TRUNCXFDF2' "$cmpxf2"; then \
      perl -0pi -e 's~(/\* convert long double to double \*/\ndouble\n__truncxfdf2)~#if !defined(__GNUC__) || __GNUC__ < 15\n#define CODEX_GCC15_LIBNIX_TRUNCXFDF2 1\n$1~' "$cmpxf2"; \
      perl -0pi -e 's~(\nextern int __cmpdf2 \(double x1, double x2\);)~\n#endif /* !defined(__GNUC__) || __GNUC__ < 15 */\n$1~' "$cmpxf2"; \
    fi && \
    if ! grep -q 'CODEX_LIBDEBUG_AFTER_LIBGCC' Makefile; then \
      perl -0pi -e 's@(# libdebug\n)@$1# CODEX_LIBDEBUG_AFTER_LIBGCC\n@' Makefile; \
    fi && \
    if ! grep -Fq '$(BUILD)/libdebug/Makefile: $(BUILD)/gcc/_libgcc_done' Makefile; then \
      LIBDEBUG_DEPS_LINE='$(BUILD)/libdebug/Makefile: $(BUILD)/gcc/_libgcc_done $(BUILD)/libnix/_done $(PROJECTS)/libdebug/configure $(shell find 2>/dev/null $(PROJECTS)/libdebug -not \( -path $(PROJECTS)/libdebug/.git -prune \) -type f)' \
        perl -0pi -e 's@^\$\(BUILD\)/libdebug/Makefile:.*$@$ENV{LIBDEBUG_DEPS_LINE}@m' Makefile; \
    fi && \
    if [ "${BUILD_AMIGA_LTO}" = "1" ]; then \
      patch --forward --batch -d projects/binutils -p1 -i /root/patches/amiga-lto-binutils.patch && \
      patch --forward --batch -d projects/gcc -p1 -i /root/patches/amiga-lto-gcc.patch && \
      perl -0pi -e 's@ifneq \(m68k-elf,\$\(TARGET\)\)\nCONFIG_BINUTILS \+= --disable-plugins\nendif\n@CONFIG_BINUTILS += --enable-plugins # CODEX_AMIGA_LTO_PLUGINS\n@' Makefile && \
      grep -q 'CODEX_AMIGA_LTO_PLUGINS' Makefile && \
      BUILD_DIR="build-$(uname -s)-m68k-amigaos" && \
      if [ -d "${BUILD_DIR}/binutils" ]; then \
        find "${BUILD_DIR}/binutils" -name config.cache -type f -delete; \
      fi && \
      if [ -d "${BUILD_DIR}/gcc" ]; then \
        find "${BUILD_DIR}/gcc" -name config.cache -type f -delete; \
      fi && \
      rm -f "${BUILD_DIR}/binutils/Makefile" "${BUILD_DIR}/binutils/_done" && \
      rm -f "${BUILD_DIR}/gcc/Makefile" "${BUILD_DIR}/gcc/_done"; \
    fi && \
    if [ "${BUILD_BEBBO_AMIGA6_PATCHES}" = "1" ]; then \
      for p in /root/patches/bebbo-amiga6/*.patch; do \
        if [ ! -f "$p" ]; then \
          echo "missing Bebbo amiga6 patch files" >&2; \
          exit 1; \
        fi; \
        patch --forward --batch -d projects/gcc -p1 -i "$p"; \
      done; \
    fi && \
    make -j $(nproc) all NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION}

# Install all SDKs
RUN NDK=${NDK_VERSION:-$([ "${BUILD_GCC_VERSION}" = "15.2" ] && echo "3.9" || echo "3.2")} && \
    cd /root/amiga-gcc && \
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
    make -j $(nproc) all-sdk NDK=${NDK} PREFIX=/opt/amiga-${BUILD_GCC_VERSION}

# Download and fix additional include files
RUN cd /root/amiga-gcc && \
    curl -o newstyle.h https://raw.githubusercontent.com/aros-development-team/AROS/master/compiler/include/devices/newstyle.h && \
    curl -o sana2.h https://raw.githubusercontent.com/aros-development-team/AROS/master/compiler/include/devices/sana2.h && \
    curl -o sana2specialstats.h https://raw.githubusercontent.com/aros-development-team/AROS/master/compiler/include/devices/sana2specialstats.h && \
    curl -o newstyle.diff https://dl.amigadev.com/newstyle.diff && \
    patch --ignore-whitespace < newstyle.diff && \
    mv -fv newstyle.h sana2.h sana2specialstats.h /opt/amiga-${BUILD_GCC_VERSION}/m68k-amigaos/ndk-include/devices/

# Build vlink and vbcc
RUN NDK=${NDK_VERSION:-$([ "${BUILD_GCC_VERSION}" = "15.2" ] && echo "3.9" || echo "3.2")} && \
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

# Install mbtaylor1982's gencrc
RUN wget -P /bin https://github.com/mbtaylor1982/gencrc/releases/latest/download/gencrc && \
    chmod +x /bin/gencrc

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
LABEL gcc.bebbo_amiga6_patches="${BUILD_BEBBO_AMIGA6_PATCHES}"
