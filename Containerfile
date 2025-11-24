FROM ubuntu:25.10

# Build arguments for configurable GCC branch
#ARG GCC_BRANCH=amiga13.3
#ARG GCC_VERSION=13.3
ARG GCC_BRANCH=amiga6
ARG GCC_VERSION=6.5.0b

ENV DEBIAN_FRONTEND=noninteractive

# Install all packages
RUN apt-get -y update && \
    apt-get -y install \
      apt-utils curl file  git jlha-utils lhasa python3 python3-pip srecord \
      wget autoconf bison flex g++ gcc gettext git libgmpxx4ldbl libgmp-dev \
      libmpfr6 libmpfr-dev libmpc3 libmpc-dev libncurses-dev make rsync \
      texinfo zip

# Make jlha the default
RUN cd /usr/bin && mv lha lha.lhasa && ln -s jlha lha

# Install amitools.
RUN apt-get -y autoremove && \
    rm -rf /usr/lib/python3.*/EXTERNALLY-MANAGED && \
    pip3 install -U git+https://github.com/cnvogelg/amitools.git

COPY vbcc.diff /root

# Install Bebbo's amiga-gcc
RUN git config --global pull.rebase false && \
    cd /root && \
    git clone --depth 1 https://github.com/AmigaPorts/m68k-amigaos-gcc amiga-gcc && \
    cd /root/amiga-gcc && \
    sed -i -r 's#\S+/gcc#https://github.com/AmigaPorts/gcc#g' default-repos && \
    mkdir -p /opt/amiga && \
    make branch branch=${GCC_BRANCH} mod=gcc && \
    make update NDK=3.2 && \
    make -j $(nproc) all NDK=3.2

# Install all SDKs
RUN cd /root/amiga-gcc && \
    make -j $(nproc) sdk=filesysbox NDK=3.2 && \
    make -j $(nproc) sdk=sdi NDK=3.2 && \
    make -j $(nproc) sdk=ahi NDK=3.2 && \
    make -j $(nproc) sdk=mhi NDK=3.2 && \
    make -j $(nproc) sdk=camd NDK=3.2 && \
    make -j $(nproc) sdk=cgx NDK=3.2 && \
    make -j $(nproc) sdk=guigfx NDK=3.2 && \
    make -j $(nproc) sdk=mui NDK=3.2 && \
    make -j $(nproc) sdk=p96 NDK=3.2 && \
    make -j $(nproc) sdk=mcc_betterstring NDK=3.2 && \
    make -j $(nproc) sdk=mcc_guigfx NDK=3.2 && \
    make -j $(nproc) sdk=mcc_nlist NDK=3.2 && \
    make -j $(nproc) sdk=mcc_texteditor NDK=3.2 && \
    make -j $(nproc) sdk=mcc_thebar NDK=3.2 && \
    make -j $(nproc) sdk=render NDK=3.2 && \
    make -j $(nproc) sdk=warp3d NDK=3.2 && \
    make -j $(nproc) all-sdk NDK=3.2

# Download and fix additional include files
RUN cd /root/amiga-gcc && \
    curl -o newstyle.h https://raw.githubusercontent.com/aros-development-team/AROS/master/compiler/include/devices/newstyle.h && \
    curl -o sana2.h https://raw.githubusercontent.com/aros-development-team/AROS/master/compiler/include/devices/sana2.h && \
    curl -o sana2specialstats.h https://raw.githubusercontent.com/aros-development-team/AROS/master/compiler/include/devices/sana2specialstats.h && \
    curl -o newstyle.diff https://dl.amigadev.com/newstyle.diff && \
    patch --ignore-whitespace < newstyle.diff && \
    mv -fv newstyle.h sana2.h sana2specialstats.h /opt/amiga/m68k-amigaos/ndk-include/devices/

# Build vlink and vbcc
RUN cd /root/amiga-gcc && \
    patch -p1 < ../vbcc.diff && \
    make -j $(nproc) vlink vbcc NDK=3.2

# Install a working VBCC
RUN mkdir -p /tmp/vbcc-targets && \
    curl -o /tmp/vbcc-targets/vbcc_target_m68k-amigaos.lha http://phoenix.owl.de/vbcc/2022-05-22/vbcc_target_m68k-amigaos.lha && \
    cd /tmp/vbcc-targets && \
    lha -x vbcc_target_m68k-amigaos.lha && \
    cd - && \
    mv /tmp/vbcc-targets/vbcc_target_m68k-amigaos/targets /opt/amiga/m68k-amigaos/vbcc/ && \
    rm -rf /tmp/vbcc-targets

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

ENV PATH=/opt/amiga/bin:$PATH

# Add labels for documentation
LABEL gcc.version="${GCC_VERSION}"
LABEL gcc.branch="${GCC_BRANCH}"

