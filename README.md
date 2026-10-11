# amiga-gcc toolchains for Linux and macOS

Build scripts, container images and prebuilt archives for the
[AmigaPorts m68k-amigaos-gcc](https://github.com/AmigaPorts/m68k-amigaos-gcc)
cross toolchain (the continuation of
[Stefan "Bebbo" Franke](https://github.com/bebbo)'s amiga-gcc).

One script, `build.sh`, builds the toolchain on Linux and macOS. The container
image and the release archives are both produced with it, so all three ways of
getting the toolchain give you the same installation.

Supported GCC versions:

| Version  | amiga-gcc branch |
|----------|------------------|
| `6.5.0b` | `amiga6`         |
| `13.4`   | `amiga13.4`      |
| `16.2`   | `amiga16.2`      |

## What is included

Each installation is a self-contained prefix with:

- GCC (C and C++) and binutils for `m68k-amigaos`, with HUNK LTO support
- GDB, vasm, vlink and vbcc
- libnix, ixemul, clib2, libpthread, libdebug and the AmigaOS NDK (3.2 by
  default)
- zlib, libpng and FreeType built for every multilib
- amitools, including the [Vamos](https://github.com/cnvogelg/amitools)
  AmigaOS emulator, `xdftool`, `romtool` and `hunktool`
- FlexCat, fd2sfd, fd2pragma, sfdc, ira and gencrc

## Getting the toolchain

### Container image

Images are published on [Docker Hub](https://hub.docker.com/r/stefanreinauer/amiga-gcc/),
with the same tags mirrored to the GitHub Container Registry
(`ghcr.io/reinauer/container-amiga-gcc`). Docker Hub is the canonical
location.

| Tag                      | Contents                       |
|--------------------------|--------------------------------|
| `gcc-v6.5.0b`, `latest`  | GCC 6.5.0b                     |
| `gcc-v13.4`              | GCC 13.4                       |
| `gcc-v16.2`              | GCC 16.2                       |
| `gcc-vVERSION-YYYYMMDD`  | A specific dated build         |

The toolchain is installed in `/opt/amiga` and is on `PATH`:

```sh
podman run --rm -v "$PWD:/src" -w /src stefanreinauer/amiga-gcc:gcc-v13.4 \
  m68k-amigaos-gcc hello.c -o hello -noixemul
```

`docker` works the same way.

### Prebuilt archives

The **Build native toolchain archives** workflow builds `.tar.xz` archives
for Linux x86_64 and macOS ARM64 for every supported version. Releases are
published on the [Releases page](https://github.com/reinauer/container-amiga-gcc/releases);
builds from every push to `main` are also kept as artifacts of their workflow
run. An archive contains a dated installation and a stable symlink to it:

```
opt/amiga-16.2-20260825/
opt/amiga-16.2 -> amiga-16.2-20260825
```

Extract it at the root of the file system so that it lands in `/opt`:

```sh
sudo tar -xJf amiga-gcc-16.2-20260825-linux-x86_64.tar.xz -C /
export PATH=/opt/amiga-16.2/bin:$PATH
```

Several versions and dates can be installed side by side.

On macOS, browser downloads may carry a quarantine flag that triggers an
"Apple could not verify" warning for every executable. If you trust the
downloaded toolchain, remove the flag after extraction:

```sh
sudo /usr/bin/xattr -rd com.apple.quarantine /opt/amiga-*-20261002/
```

Replace `20261002` with the date of your installation. This only clears the
flag on those directories; it does not disable Gatekeeper.

### Building from source

```sh
./build.sh                       # 6.5.0b, 13.4 and 16.2 into /opt/amiga-vVERSION-YYYYMMDD
./build.sh --version 16.2 --prefix /opt/amiga-16.2
```

On Ubuntu the script installs missing packages with `apt-get` (`--skip-apt`
to opt out). On macOS it installs its dependencies with Homebrew
(`--skip-brew` to opt out) and builds with Homebrew GCC.

Run `./build.sh --help` for all options, including the NDK version, install
prefix layout, host compilers and reuse of existing source trees.

To build a container image yourself:

```sh
podman build --build-arg BUILD_GCC_VERSION=16.2 \
  --build-arg BUILD_GCC_BRANCH=amiga16.2 -t amiga-gcc:16.2 .
```

## Usage notes

### Running programs with Vamos

Vamos runs AmigaOS command-line programs on the host, which is handy for
tests and CI:

```sh
m68k-amigaos-gcc hello.c -o hello -noixemul
vamos hello
```

### vbcc

`bin/vc` is a wrapper that points `VBCC` at the installation's own
`m68k-amigaos/vbcc` directory, so no environment setup is needed and a `VBCC`
variable set for another toolchain is ignored.

```sh
vc hello.c -o hello            # default config
vc +aos68k hello.c -o hello    # select a target config
```

The available configs are `aos68k`, `aos68km`, `aos68kr` and `kick13`. They
live in `m68k-amigaos/vbcc/config`, and explicit config paths and
current-directory overrides work as usual.

## History

This repository started as a fork of
[Sebastian Bergmann](https://github.com/sebastianbergmann)'s
`container-amiga-gcc`, a Dockerfile that built amiga-gcc in a container.
It has since been rewritten: the build now lives in `build.sh` and runs
natively on Linux and macOS, several GCC versions are built and published
side by side, and native toolchain archives are produced alongside the
container images. Thanks to Sebastian for the original work.
