# amiga-gcc toolchains for Linux and macOS

Build scripts, container images and prebuilt archives for the
[AmigaPorts m68k-amigaos-gcc](https://github.com/AmigaPorts/m68k-amigaos-gcc)
cross toolchain (the continuation of
[Stefan "Bebbo" Franke](https://github.com/bebbo)'s amiga-gcc), and for the
AmigaPorts `ppc-amigaos` (AmigaOS 4) cross toolchain.

One script, `build.sh`, builds the toolchain on Linux and macOS. The container
image and the release archives are both produced with it, so all three ways of
getting the toolchain give you the same installation.

Supported GCC versions:

| Version  | amiga-gcc branch |
|----------|------------------|
| `6.5.0b` | `amiga6`         |
| `13.4`   | `amiga13.4`      |
| `16.2`   | `amiga16.2`      |

`ppc-amigaos` GCC 16.2 is built from the same
[AmigaPorts gcc](https://github.com/AmigaPorts/gcc) branch, `amiga16.2`, and
binutils 2.46 from the
[AmigaPorts binutils-gdb](https://github.com/AmigaPorts/binutils-gdb) branch
`amiga-2.46`.

## What is included

Each `m68k-amigaos` installation is a self-contained prefix with:

- GCC (C and C++) and binutils for `m68k-amigaos`, with HUNK LTO support
- GDB, vasm, vlink and vbcc
- libnix, ixemul, clib2, libpthread, libdebug and the AmigaOS NDK (3.2 by
  default)
- zlib, libpng and FreeType built for every multilib
- amitools, including the [Vamos](https://github.com/cnvogelg/amitools)
  AmigaOS emulator, `xdftool`, `romtool` and `hunktool`
- FlexCat, fd2sfd, fd2pragma, sfdc, ira and gencrc

Each `ppc-amigaos` installation has:

- GCC (C and C++) and binutils for `ppc-amigaos`
- the AmigaOS 4 SDK (54.16 by default), downloaded from Hyperion, with its
  newlib runtime
- clib2 and clib4, built with the new compiler
- lha

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
| `gcc-v16.2-ppc`          | GCC 16.2 for `ppc-amigaos`     |
| `gcc-vVERSION-YYYYMMDD`  | A specific dated build         |

The toolchain is installed in `/opt/amiga` (`/opt/amiga-ppc` for
`ppc-amigaos`) and is on `PATH`:

```sh
podman run --rm -v "$PWD:/src" -w /src stefanreinauer/amiga-gcc:gcc-v13.4 \
  m68k-amigaos-gcc hello.c -o hello -noixemul
podman run --rm -v "$PWD:/src" -w /src stefanreinauer/amiga-gcc:gcc-v16.2-ppc \
  ppc-amigaos-gcc hello.c -o hello
```

`docker` works the same way.

### Prebuilt archives

The **Build native toolchain archives** workflow builds `.tar.xz` archives
for Linux x86_64 and macOS ARM64 for every supported version. Releases are
published on the [Releases page](https://github.com/reinauer/container-amiga-gcc/releases);
builds from every push to `main` are also kept as artifacts of their workflow
run.

A release is cut by running the workflow by hand; it tags the commit it ran
from with the build date, such as `v2026-10-28`. Given a release tag of
[AmigaPorts/m68k-amigaos-gcc](https://github.com/AmigaPorts/m68k-amigaos-gcc/tags),
GCC 16.2 is built from that release instead of the branches, for
m68k-amigaos and ppc-amigaos alike, and the release is named after both
(`v2026-10-28-16.2-rc21`). A new upstream release needs no change here, just
another run:

```sh
gh workflow run toolchain-archives.yml -f release_tag=v16.2-rc22
```

An archive contains a dated installation and a stable symlink to it:

```
opt/amiga-16.2-20260825/
opt/amiga-16.2 -> amiga-16.2-20260825
```

`ppc-amigaos` archives are named `amiga-ppc-gcc-…` and install
`opt/amiga-ppc-16.2-…` and `opt/amiga-ppc-16.2`.

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
./build.sh --target ppc-amigaos  # 16.2 into /opt/amiga-ppc-v16.2-YYYYMMDD
```

On Ubuntu the script installs missing packages with `apt-get` (`--skip-apt`
to opt out). On macOS it installs its dependencies with Homebrew
(`--skip-brew` to opt out) and builds with Homebrew GCC.

Run `./build.sh --help` for all options, including the NDK version, install
prefix layout, host compilers and reuse of existing source trees. For
`ppc-amigaos`, `--sdk-archive` uses a local copy of the SDK instead of
downloading it.

### Building container images

`update_docker.sh` builds the images the same way as the published ones: every
supported version from its branch, tagged `gcc-vVERSION` and
`gcc-vVERSION-YYYYMMDD` (`gcc-vVERSION-ppc` and `gcc-vVERSION-ppc-YYYYMMDD`
for `ppc-amigaos`), with `latest` pointing at GCC 6.5.0b. CI runs this
script too. Use `--no-push` to only build and tag them locally:

```sh
./update_docker.sh --no-push            # asks before each step
./update_docker.sh --no-push --no-skip  # runs all steps without asking
```

Set `DOCKER_CLI=podman` to build with Podman instead of Docker.

To build a single image by hand:

```sh
podman build --build-arg BUILD_GCC_VERSION=16.2 \
  --build-arg BUILD_GCC_BRANCH=amiga16.2 -t amiga-gcc:16.2 .
```

With Docker, name the `Containerfile` explicitly:

```sh
docker build -f Containerfile --build-arg BUILD_GCC_VERSION=16.2 \
  --build-arg BUILD_GCC_BRANCH=amiga16.2 -t amiga-gcc:16.2 .
```

For `ppc-amigaos`, add `--build-arg BUILD_TARGET=ppc-amigaos` and pass the
AmigaPorts/gcc ref as `BUILD_GCC_BRANCH`:

```sh
podman build --build-arg BUILD_TARGET=ppc-amigaos \
  --build-arg BUILD_GCC_VERSION=16.2 \
  --build-arg BUILD_GCC_BRANCH=amiga16.2 -t amiga-gcc:16.2-ppc .
```

## Publishing images

Every push to `main` builds the images and publishes them to GHCR. Docker
Hub is updated from there, without rebuilding:

```sh
docker login docker.io
./copy_to_dockerhub.sh
```

`copy_to_dockerhub.sh` finds the newest dated build on GHCR, lists its tags
(`gcc-vVERSION`, `gcc-vVERSION-YYYYMMDD` and `latest`) and asks before
copying them. It also points `latest` of the retired
`stefanreinauer/amigappc-gcc` repository at the newest `gcc-vVERSION-ppc`
image, for users of the old ppc-amigaos images. Tags that are already up to
date are skipped. Use `--dry-run` to only list them and `--yes` to copy
without asking.

Without `--no-push`, `update_docker.sh` builds all versions locally and
pushes them to Docker Hub directly, asking before each step.

Both scripts read the registry accounts from `registry.conf`. To publish from
a fork, change the user and repository names there:

```sh
GITHUB_USER="reinauer"              # ghcr.io/GITHUB_USER/GITHUB_REPO
GITHUB_REPO="container-amiga-gcc"
DOCKERHUB_USER="stefanreinauer"     # docker.io/DOCKERHUB_USER/DOCKERHUB_REPO
DOCKERHUB_REPO="amiga-gcc"
```

A fork should also empty `DOCKERHUB_PPC_LEGACY_REPOSITORY`, which names the
retired `amigappc-gcc` repository.

The `--repository`, `--source` and `--destination` options override these
for a single run. The GitHub workflows don't use `registry.conf`; they
publish to the GHCR package of the repository they run in.

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

### AmigaOS 4 C runtimes

`ppc-amigaos-gcc` links against newlib by default. `-mcrt=clib2` and
`-mcrt=clib4` select the other runtimes. `-athread=native` or `single`
selects the thread model for C++, as does `-athread=pthread` with clib4:

```sh
ppc-amigaos-gcc -O2 hello.c -o hello
ppc-amigaos-g++ -O2 -mcrt=clib4 -athread=native hello.cc -o hello
```

## History

This repository started as a fork of
[Sebastian Bergmann](https://github.com/sebastianbergmann)'s
`container-amiga-gcc`, a Dockerfile that built amiga-gcc in a container.
It has since been rewritten: the build now lives in `build.sh` and runs
natively on Linux and macOS, several GCC versions are built and published
side by side, and native toolchain archives are produced alongside the
container images. Thanks to Sebastian for the original work.
