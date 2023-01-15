FROM ubuntu:22.10

RUN export DEBIAN_FRONTEND=noninteractive && \
    apt-get update && \
    apt-get install -y \
    autoconf \
    bison \
    flex \
    g++ \
    gcc \
    gettext \
    git \
    lhasa \
    jlha-utils \
    libgmpxx4ldbl \
    libgmp-dev \
    libmpfr6 \
    libmpfr-dev \
    libmpc3 \
    libmpc-dev \
    libncurses-dev \
    make \
    rsync \
    texinfo\
    wget \
    && rm -rf /var/lib/apt/lists/* && \
    git config --global pull.rebase false && \
    cd /root && \
    git clone --depth 1 https://github.com/bebbo/amiga-gcc.git && \
    cd /root/amiga-gcc && \
    mkdir -p /opt/amiga && \
    make update && \
    make -j4 all && \
    cd / && \
    rm -rf /root/amiga-gcc && \
    apt-get purge -y \
    libgmp-dev \
    libmpfr-dev \
    libmpc-dev \
    libncurses-dev \
    rsync \
    texinfo\
    wget \
    && apt-get -y autoremove \
    && cd /usr/bin && mv lha lha.lhasa && ln -s jlha lha

ENV PATH /opt/amiga/bin:$PATH

