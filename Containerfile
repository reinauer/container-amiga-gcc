FROM ubuntu:25.10

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
    sed -i -r 's#\S+/gcc#https://github.com/liv2/gcc#g' default-repos && \
    mkdir -p /opt/amiga && \
    make branch branch=amiga13.3 mod=gcc && \
    make update && \
    patch -p1 < ../vbcc.diff && \
    make -j4 all vlink vbcc NDK=3.2 && \
    cd / && \
    rm -rf /root/amiga-gcc

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
RUN rm -rf /var/lib/apt/lists/* && \
    apt-get purge -y \
      libgmp-dev libmpfr-dev libmpc-dev rsync texinfo && \
    apt-get -y autoremove

ENV PATH /opt/amiga/bin:$PATH

