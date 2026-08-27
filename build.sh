#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_OS="$(uname -s)"
case "$CURRENT_OS" in
  Linux) BUILD_HOST="linux" ;;
  Darwin) BUILD_HOST="mac" ;;
  *)
    printf 'error: unsupported build host: %s\n' "$CURRENT_OS" >&2
    exit 1
    ;;
esac

REPO_URL="https://github.com/AmigaPorts/m68k-amigaos-gcc"
GCC_REPO_URL="https://github.com/AmigaPorts/gcc"
GENCRC_REPO_URL="https://github.com/mbtaylor1982/gencrc.git"
NDK_VERSION="3.2"
PREFIX_ROOT="/opt"
DATE_STAMP="${BUILD_DATE:-$(date +%Y%m%d)}"
PREFIX_TEMPLATE="amiga-v{version}-{date}"
if [[ "$BUILD_HOST" == "mac" ]]; then
  WORKDIR="${SCRIPT_DIR}/.mac-build"
else
  WORKDIR="${SCRIPT_DIR}/.linux-build"
fi
JOBS=""
INSTALL_PACKAGES=1
INSTALL_AMITOOLS=1
REUSE_SOURCE=0
DEFAULT_SYMLINK_VERSION=""
PREFIX_OVERRIDE=""
ENABLE_AMIGA_LTO=1
HOST_CC="${CC:-}"
HOST_CXX="${CXX:-}"
GENCRC_BIN=""
VERSION_SPECS=()

APT_PACKAGES=(
  apt-utils
  autoconf
  automake
  bison
  build-essential
  ca-certificates
  curl
  file
  flex
  g++
  gcc
  gettext
  git
  libgmp-dev
  libmpc-dev
  libmpfr-dev
  libncurses-dev
  make
  patch
  perl
  python3
  python3-pip
  python3-venv
  rsync
  srecord
  texinfo
  wget
  zip
)

BREW_PACKAGES=(
  bash
  wget
  make
  gmp
  mpfr
  libmpc
  flex
  gettext
  gnu-sed
  texinfo
  autoconf
  automake
  bison
  rsync
  srecord
  gperf
  ncurses
  readline
  python
)

usage() {
  local package_option workdir_default

  if [[ "$BUILD_HOST" == "mac" ]]; then
    package_option="  --skip-brew                Do not install Homebrew formulae"
    workdir_default="./.mac-build"
  else
    package_option="  --skip-apt                 Do not install missing Ubuntu packages"
    workdir_default="./.linux-build"
  fi

  cat <<EOF
Usage: ./build.sh [options]

Build Bebbo/AmigaPorts m68k-amigaos-gcc natively on Linux or macOS using the
same high-level steps as Containerfile.

Defaults:
  versions:       6.5.0b, 13.4, 16.2
  prefixes:       /opt/amiga-vVERSION-YYYYMMDD
  NDK:            3.2
  Amiga LTO:      enabled
  source workdir: ${workdir_default}

Options:
  --ndk VERSION              NDK version passed to make (default: 3.2)
  --version VERSION[:BRANCH] Build one version; repeat for multiple versions
                             Known versions: 13.4 -> amiga13.4,
                             6.5.0b -> amiga6, 15.2 -> amiga15.2,
                             16.2 -> amiga16.2
  --prefix-root DIR          Install under DIR/TEMPLATE (default: /opt)
  --prefix DIR               Install a single requested version into DIR
  --prefix-template TEMPLATE Directory name under --prefix-root.
                             Supports {version} and {date}
                             (default: amiga-v{version}-{date})
  --date YYYYMMDD            Date stamp for the default prefix template
                             (default: today or BUILD_DATE)
  --workdir DIR              Build workspace (default: ${workdir_default})
  --jobs N                   Parallel make jobs (default: nproc)
  --repo URL                 Main amiga-gcc repository URL
  --cc PATH_OR_NAME          Host C compiler (default: prefer gcc-15/gcc)
  --cxx PATH_OR_NAME         Host C++ compiler (default: prefer g++-15/g++)
  --enable-amiga-lto         Enable Amiga HUNK LTO support (default)
  --disable-amiga-lto        Disable Amiga HUNK LTO support
                             LTO is supported for GCC 6.5.0b, 13.4, and 16.2.
${package_option}
  --skip-amitools            Do not install amitools/Vamos into each prefix
  --reuse-source             Reuse existing per-version source trees
                             Generated build directories are reused only when
                             they match the requested prefix and LTO mode
  --link-default VERSION     Create/update /opt/amiga -> the matching versioned prefix
  -h, --help                 Show this help

Examples:
  ./build.sh
  ./build.sh --date 20260518
  ./build.sh --ndk 3.9 --version 13.4
  ./build.sh --version 13.4 --prefix /opt/amiga-13.4-lto
  ./build.sh --version 6.5.0b --disable-amiga-lto
  ./build.sh --cc gcc-12 --cxx g++-12
  ./build.sh --version 16.2 --prefix /opt/amiga-16.2
  ./build.sh --version 15.2:amiga15.2 --disable-amiga-lto --link-default 15.2
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

append_unique_path() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    case ":${PATH}:" in
      *":${dir}:"*) ;;
      *) PATH="${PATH}:${dir}" ;;
    esac
  fi
}

prepend_unique_path() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    case ":${PATH}:" in
      *":${dir}:"*) ;;
      *) PATH="${dir}:${PATH}" ;;
    esac
  fi
}

detect_jobs() {
  if [[ -n "$JOBS" ]]; then
    return
  fi

  if [[ "$BUILD_HOST" == "mac" ]]; then
    JOBS="$(sysctl -n hw.ncpu 2>/dev/null || printf '4')"
  else
    JOBS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')"
  fi
  if [[ -z "$JOBS" || "$JOBS" -lt 1 ]]; then
    JOBS=4
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ndk)
        [[ $# -ge 2 ]] || die "--ndk requires a value"
        NDK_VERSION="$2"
        shift 2
        ;;
      --version)
        [[ $# -ge 2 ]] || die "--version requires a value"
        VERSION_SPECS+=("$2")
        shift 2
        ;;
      --prefix-root)
        [[ $# -ge 2 ]] || die "--prefix-root requires a value"
        PREFIX_ROOT="${2%/}"
        shift 2
        ;;
      --prefix)
        [[ $# -ge 2 ]] || die "--prefix requires a value"
        PREFIX_OVERRIDE="${2%/}"
        shift 2
        ;;
      --prefix-template)
        [[ $# -ge 2 ]] || die "--prefix-template requires a value"
        PREFIX_TEMPLATE="$2"
        shift 2
        ;;
      --date)
        [[ $# -ge 2 ]] || die "--date requires a value"
        DATE_STAMP="$2"
        shift 2
        ;;
      --workdir)
        [[ $# -ge 2 ]] || die "--workdir requires a value"
        WORKDIR="${2%/}"
        shift 2
        ;;
      --jobs)
        [[ $# -ge 2 ]] || die "--jobs requires a value"
        JOBS="$2"
        shift 2
        ;;
      --repo)
        [[ $# -ge 2 ]] || die "--repo requires a value"
        REPO_URL="$2"
        shift 2
        ;;
      --cc)
        [[ $# -ge 2 ]] || die "--cc requires a value"
        HOST_CC="$2"
        shift 2
        ;;
      --cxx)
        [[ $# -ge 2 ]] || die "--cxx requires a value"
        HOST_CXX="$2"
        shift 2
        ;;
      --enable-amiga-lto)
        ENABLE_AMIGA_LTO=1
        shift
        ;;
      --disable-amiga-lto)
        ENABLE_AMIGA_LTO=0
        shift
        ;;
      --skip-apt)
        [[ "$BUILD_HOST" == "linux" ]] || die "unknown option: $1"
        INSTALL_PACKAGES=0
        shift
        ;;
      --skip-brew)
        [[ "$BUILD_HOST" == "mac" ]] || die "unknown option: $1"
        INSTALL_PACKAGES=0
        shift
        ;;
      --skip-amitools)
        INSTALL_AMITOOLS=0
        shift
        ;;
      --reuse-source)
        REUSE_SOURCE=1
        shift
        ;;
      --link-default)
        [[ $# -ge 2 ]] || die "--link-default requires a version"
        DEFAULT_SYMLINK_VERSION="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done

  if [[ ${#VERSION_SPECS[@]} -eq 0 ]]; then
    VERSION_SPECS=("6.5.0b" "13.4" "16.2")
  fi

  if [[ -n "$PREFIX_OVERRIDE" && ${#VERSION_SPECS[@]} -ne 1 ]]; then
    die "--prefix requires exactly one --version"
  fi

  if [[ "$ENABLE_AMIGA_LTO" -eq 1 ]]; then
    local lto_spec
    for lto_spec in "${VERSION_SPECS[@]}"; do
      case "${lto_spec%%:*}" in
        6.5.0b|13.4|16.2) ;;
        *) die "Amiga LTO currently supports --version 6.5.0b, 13.4, or 16.2" ;;
      esac
    done
  fi

}

prefix_for_version() {
  local version="$1"
  local prefix_name="$PREFIX_TEMPLATE"

  prefix_name="${prefix_name//\{version\}/$version}"
  prefix_name="${prefix_name//\{date\}/$DATE_STAMP}"
  printf '%s/%s\n' "$PREFIX_ROOT" "$prefix_name"
}

version_from_spec() {
  printf '%s\n' "${1%%:*}"
}

ndk_for_version() {
  local version="$1"
  : "$version"
  printf '%s\n' "$NDK_VERSION"
}

branch_from_spec() {
  local spec="$1"
  local version

  if [[ "$spec" == *:* ]]; then
    printf '%s\n' "${spec#*:}"
    return
  fi

  version="$(version_from_spec "$spec")"
  case "$version" in
    6.5.0b) printf '%s\n' "amiga6" ;;
    13.4) printf '%s\n' "amiga13.4" ;;
    15.2) printf '%s\n' "amiga15.2" ;;
    16.2) printf '%s\n' "amiga16.2" ;;
    *) die "no branch mapping for GCC version ${version}; use --version ${version}:BRANCH" ;;
  esac
}

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

ensure_apt() {
  if [[ "$INSTALL_PACKAGES" -eq 0 ]]; then
    log "Skipping Ubuntu package installation"
    return
  fi

  command -v dpkg-query >/dev/null 2>&1 || die "dpkg-query not found"
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found"

  local missing=()
  local package
  for package in "${APT_PACKAGES[@]}"; do
    if ! package_installed "$package"; then
      missing+=("$package")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log "Installing Ubuntu packages: ${missing[*]}"
    if [[ "$(id -u)" -eq 0 ]]; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get -y install "${missing[@]}"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo apt-get update
      sudo DEBIAN_FRONTEND=noninteractive apt-get -y install "${missing[@]}"
    else
      die "missing Ubuntu packages: ${missing[*]}. Install them with: sudo apt-get install ${missing[*]}"
    fi
  else
    log "Ubuntu packages already installed"
  fi
}

brew_prefix() {
  brew --prefix "$1" 2>/dev/null || true
}

ensure_brew() {
  command -v brew >/dev/null 2>&1 || die "Homebrew is required. Install it from https://brew.sh/ first."

  if [[ "$INSTALL_PACKAGES" -eq 0 ]]; then
    log "Skipping Homebrew package installation"
    return
  fi

  local missing=()
  local package
  for package in "${BREW_PACKAGES[@]}"; do
    if ! brew list --formula "$package" >/dev/null 2>&1; then
      missing+=("$package")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log "Installing Homebrew packages: ${missing[*]}"
    brew install "${missing[@]}"
  else
    log "Homebrew packages already installed"
  fi

  ensure_host_gcc_brew
}

ensure_host_gcc_brew() {
  if [[ -n "$HOST_CC" && -n "$HOST_CXX" ]]; then
    return
  fi

  if command -v gcc-15 >/dev/null 2>&1 && command -v g++-15 >/dev/null 2>&1; then
    return
  fi

  if brew info --formula gcc@15 >/dev/null 2>&1; then
    if ! brew list --formula gcc@15 >/dev/null 2>&1; then
      log "Installing Homebrew gcc@15"
      brew install gcc@15
    fi
    return
  fi

  if ! brew list --formula gcc >/dev/null 2>&1; then
    log "gcc@15 formula not available; installing Homebrew gcc"
    brew install gcc
  fi
}

add_brew_flags() {
  local prefix="$1"
  if [[ -n "$prefix" && -d "$prefix" ]]; then
    export CPPFLAGS="-I${prefix}/include ${CPPFLAGS}"
    export LDFLAGS="-L${prefix}/lib ${LDFLAGS}"
    if [[ -d "${prefix}/lib/pkgconfig" ]]; then
      export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
    fi
  fi
}

configure_macos_tools() {
  local brew_root bash_prefix bison_prefix flex_prefix gettext_prefix gnu_sed_prefix
  local make_prefix texinfo_prefix gcc15_prefix gcc_prefix gmp_prefix mpfr_prefix mpc_prefix
  local ncurses_prefix readline_prefix

  brew_root="$(brew --prefix)"
  bash_prefix="$(brew_prefix bash)"
  bison_prefix="$(brew_prefix bison)"
  flex_prefix="$(brew_prefix flex)"
  gettext_prefix="$(brew_prefix gettext)"
  gnu_sed_prefix="$(brew_prefix gnu-sed)"
  make_prefix="$(brew_prefix make)"
  texinfo_prefix="$(brew_prefix texinfo)"
  gcc15_prefix="$(brew_prefix gcc@15)"
  gcc_prefix="$(brew_prefix gcc)"
  gmp_prefix="$(brew_prefix gmp)"
  mpfr_prefix="$(brew_prefix mpfr)"
  mpc_prefix="$(brew_prefix libmpc)"
  ncurses_prefix="$(brew_prefix ncurses)"
  readline_prefix="$(brew_prefix readline)"

  prepend_unique_path "${make_prefix}/libexec/gnubin"
  prepend_unique_path "${gnu_sed_prefix}/libexec/gnubin"
  prepend_unique_path "${bison_prefix}/bin"
  prepend_unique_path "${flex_prefix}/bin"
  prepend_unique_path "${gettext_prefix}/bin"
  prepend_unique_path "${texinfo_prefix}/bin"
  prepend_unique_path "${gcc_prefix}/bin"
  prepend_unique_path "${gcc15_prefix}/bin"
  prepend_unique_path "${brew_root}/bin"
  append_unique_path "${brew_root}/sbin"
  export PATH

  export CPPFLAGS="${CPPFLAGS:-}"
  export LDFLAGS="${LDFLAGS:-}"
  export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
  add_brew_flags "$gmp_prefix"
  add_brew_flags "$mpfr_prefix"
  add_brew_flags "$mpc_prefix"
  add_brew_flags "$ncurses_prefix"
  add_brew_flags "$readline_prefix"

  if [[ -n "$gettext_prefix" ]]; then
    export ACLOCAL_PATH="${gettext_prefix}/share/aclocal${ACLOCAL_PATH:+:${ACLOCAL_PATH}}"
  fi

  if [[ -z "$HOST_CC" ]]; then
    HOST_CC="$(find_host_compiler gcc)"
  fi

  if [[ -z "$HOST_CXX" ]]; then
    HOST_CXX="$(find_host_compiler g++)"
  fi

  verify_host_compiler "$HOST_CC" "C" "--cc"
  verify_host_compiler "$HOST_CXX" "C++" "--cxx"
  log "Using host compilers: CC=${HOST_CC} CXX=${HOST_CXX}"

  export CC="$HOST_CC"
  export CXX="$HOST_CXX"

  if command -v gmake >/dev/null 2>&1; then
    MAKE_BIN="$(command -v gmake)"
  else
    MAKE_BIN="$(command -v make)"
  fi
  [[ -n "$MAKE_BIN" ]] || die "make/gmake not found"

  if [[ -x "${brew_root}/bin/bash" ]]; then
    MAKE_SHELL="${brew_root}/bin/bash"
  elif [[ -n "$bash_prefix" && -x "${bash_prefix}/bin/bash" ]]; then
    MAKE_SHELL="${bash_prefix}/bin/bash"
  else
    die "Homebrew bash not found"
  fi
  export MAKE_SHELL

  PATCH_BIN="$(command -v gpatch || command -v patch || true)"
  [[ -n "$PATCH_BIN" ]] || die "patch not found"
  export PATCH_BIN

  command -v git >/dev/null 2>&1 || die "git not found"
  command -v curl >/dev/null 2>&1 || die "curl not found"
  command -v python3 >/dev/null 2>&1 || die "python3 not found"

  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=pull.rebase
  export GIT_CONFIG_VALUE_0=false
}

configure_linux_tools() {
  if [[ -z "$HOST_CC" ]]; then
    HOST_CC="$(find_host_compiler gcc)"
  fi

  if [[ -z "$HOST_CXX" ]]; then
    HOST_CXX="$(find_host_compiler g++)"
  fi

  verify_host_compiler "$HOST_CC" "C" "--cc"
  verify_host_compiler "$HOST_CXX" "C++" "--cxx"
  log "Using host compilers: CC=${HOST_CC} CXX=${HOST_CXX}"

  export CC="$HOST_CC"
  export CXX="$HOST_CXX"

  MAKE_BIN="$(command -v make || true)"
  [[ -n "$MAKE_BIN" ]] || die "make not found"

  MAKE_SHELL="$(command -v bash || true)"
  [[ -n "$MAKE_SHELL" ]] || die "bash not found"
  export MAKE_SHELL

  PATCH_BIN="$(command -v patch || true)"
  [[ -n "$PATCH_BIN" ]] || die "patch not found"
  export PATCH_BIN

  command -v git >/dev/null 2>&1 || die "git not found"
  command -v curl >/dev/null 2>&1 || die "curl not found"
  command -v makeinfo >/dev/null 2>&1 || die "makeinfo not found; install the texinfo package"
  command -v srec_cat >/dev/null 2>&1 || die "srec_cat not found; install the srecord package"
  command -v python3 >/dev/null 2>&1 || die "python3 not found"
  command -v perl >/dev/null 2>&1 || die "perl not found"

  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=pull.rebase
  export GIT_CONFIG_VALUE_0=false
}

find_host_compiler() {
  local base="$1"
  local candidate
  local option

  if [[ "$base" == "gcc" ]]; then
    option="--cc"
  else
    option="--cxx"
  fi

  for candidate in "${base}-15" "${base}-16" "${base}-14" "${base}-13" "${base}-12" "$base"; do
    if command -v "$candidate" >/dev/null 2>&1 && is_gnu_compiler "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  if [[ "$BUILD_HOST" == "mac" ]]; then
    die "no GNU ${base} compiler found; install gcc@15/Homebrew gcc or pass ${option}"
  fi
  die "no GNU ${base} compiler found; install gcc/g++ or pass ${option}"
}

is_gnu_compiler() {
  local compiler="$1"
  local first_line

  first_line="$("$compiler" --version 2>/dev/null | head -n 1 || true)"
  if [[ "$BUILD_HOST" == "mac" ]]; then
    [[ "$first_line" == *"GCC"* || "$first_line" == *"Free Software Foundation"* || "$first_line" == *"gcc"* ]]
  else
    [[ "$first_line" == *"GCC"* || "$first_line" == *"Free Software Foundation"* || "$first_line" == *"gcc"* || "$first_line" == *"g++"* ]]
  fi
}

verify_host_compiler() {
  local compiler="$1"
  local label="$2"
  local option="$3"

  command -v "$compiler" >/dev/null 2>&1 || die "${label} compiler not found: ${compiler}"
  is_gnu_compiler "$compiler" || die "${label} compiler is not GNU GCC: ${compiler}; pass ${option}"
}

install_amitools() {
  local prefix="$1"

  if [[ "$INSTALL_AMITOOLS" -eq 0 ]]; then
    log "Skipping amitools installation"
    return
  fi

  local venv="${prefix}/libexec/amitools"
  local tool

  log "Installing amitools with Vamos support into ${venv}"
  mkdir -p "${prefix}/libexec" "${prefix}/bin"
  python3 -m venv "$venv"
  "${venv}/bin/python" -m pip install -U pip
  "${venv}/bin/python" -m pip install -U \
    "amitools[vamos] @ git+https://github.com/cnvogelg/amitools.git"

  while IFS= read -r tool; do
    [[ -n "$tool" ]] || continue
    [[ -x "${venv}/bin/${tool}" ]] \
      || die "missing amitools entry point: ${venv}/bin/${tool}"
    ln -sfn "../libexec/amitools/bin/${tool}" "${prefix}/bin/${tool}"
  done < <(
    "${venv}/bin/python" -c '
from importlib.metadata import distribution
for entry_point in distribution("amitools").entry_points:
    if entry_point.group == "console_scripts":
        print(entry_point.name)
'
  )

  prepend_unique_path "${venv}/bin"
  export PATH
}

ensure_prefix_writable() {
  local prefix="$1"
  if [[ -d "$prefix" && -w "$prefix" ]]; then
    return
  fi

  log "Preparing writable prefix ${prefix}"
  if [[ "$BUILD_HOST" == "mac" ]]; then
    sudo mkdir -p "$prefix"
    sudo chown -R "$(id -u):$(id -g)" "$prefix"
    [[ -w "$prefix" ]] || die "prefix is not writable: ${prefix}"
    return
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    mkdir -p "$prefix"
    chown -R "$(id -u):$(id -g)" "$prefix"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo mkdir -p "$prefix"
    sudo chown -R "$(id -u):$(id -g)" "$prefix"
  else
    die "prefix is not writable: ${prefix}. Create it and chown it to $(id -un), or choose a writable --prefix-root"
  fi

  [[ -w "$prefix" ]] || die "prefix is not writable: ${prefix}"
}

safe_remove_source() {
  local src="$1"

  [[ -n "$src" ]] || die "empty source path"
  [[ "$src" != "/" ]] || die "refusing to remove /"

  if [[ -d "$src" ]]; then
    rm -rf "$src"
  fi
}

prepare_source() {
  local version="$1"
  local src="$2"

  if [[ "$REUSE_SOURCE" -eq 0 ]]; then
    safe_remove_source "$src"
  fi

  if [[ ! -d "${src}/.git" ]]; then
    log "Cloning ${REPO_URL} for GCC ${version}"
    mkdir -p "$(dirname "$src")"
    git clone --depth 1 "$REPO_URL" "$src"
  else
    log "Reusing source tree ${src}"
  fi

  (
    cd "$src"
    perl -pi -e "s#\\S+/gcc#${GCC_REPO_URL}#g" default-repos
  )
}

prepare_gencrc() {
  local src="${WORKDIR}/gencrc"

  if [[ "$REUSE_SOURCE" -eq 0 ]]; then
    safe_remove_source "$src"
  fi

  if [[ ! -d "${src}/.git" ]]; then
    log "Cloning gencrc"
    mkdir -p "$WORKDIR"
    git clone --depth 1 "$GENCRC_REPO_URL" "$src"
  else
    log "Reusing gencrc source tree ${src}"
  fi

  # gencrc uses the non-standard uint typedef supplied by some Unix libc
  # implementations. Use the equivalent standard C type so it also builds on
  # macOS, where that typedef is not available.
  if grep -qw 'uint' "${src}/gencrc.c"; then
    perl -pi -e 's/\buint\b/unsigned int/g' "${src}/gencrc.c"
  fi
  if grep -qw 'uint' "${src}/gencrc.c"; then
    die "failed to replace non-standard uint typedef in ${src}/gencrc.c"
  fi

  log "Building gencrc"
  (
    cd "$src"
    "$MAKE_BIN" -j "$JOBS" CC="$HOST_CC" SHELL="$MAKE_SHELL"
  )

  GENCRC_BIN="${src}/gencrc"
  [[ -x "$GENCRC_BIN" ]] || die "gencrc build did not produce ${GENCRC_BIN}"
}

install_gencrc() {
  local prefix="$1"

  [[ -x "$GENCRC_BIN" ]] || die "gencrc has not been built"
  log "Installing gencrc into ${prefix}/bin"
  mkdir -p "${prefix}/bin"
  install -m 755 "$GENCRC_BIN" "${prefix}/bin/gencrc"
}

build_dir_has_foreign_amiga_prefix() {
  local build="$1"
  local prefix="$2"
  local file

  while IFS= read -r file; do
    if LC_ALL=C grep -E "(^|[[:space:]'])--prefix=/opt/amiga-|^(prefix|exec_prefix|libdir|tooldir|includedir)[[:space:]]*=[[:space:]]*/opt/amiga-" "$file" \
        | grep -Fv -- "$prefix" >/dev/null 2>&1; then
      return 0
    fi
  done < <(find "$build" \( -name config.log -o -name config.status -o -name Makefile \) -type f 2>/dev/null)

  return 1
}

reset_variant_build_dir() {
  local src="$1"
  local prefix="$2"
  local build="${src}/build-$(uname -s)-m68k-amigaos"
  local stamp="${build}/.build_${BUILD_HOST}_variant"
  local stamp_text

  [[ "$REUSE_SOURCE" -eq 1 ]] || return 0

  stamp_text="$(printf 'prefix=%s\nlto=%s' "$prefix" "$ENABLE_AMIGA_LTO")"
  if [[ -f "$stamp" && "$(cat "$stamp")" == "$stamp_text" ]]; then
    return
  fi

  if [[ -d "$build" ]]; then
    if [[ -f "$stamp" ]] || build_dir_has_foreign_amiga_prefix "$build" "$prefix"; then
      log "Removing generated build directory for ${prefix}"
      safe_remove_source "$build"
    fi
  fi

  mkdir -p "$build"
  printf 'prefix=%s\nlto=%s\n' "$prefix" "$ENABLE_AMIGA_LTO" > "$stamp"
}

patch_libdebug_ordering() {
  local src="$1"
  local makefile="${src}/Makefile"
  local deps_line

  [[ -f "$makefile" ]] || return 0

  deps_line='$(BUILD)/libdebug/Makefile: $(BUILD)/gcc/_libgcc_done $(BUILD)/libnix/_done $(PROJECTS)/libdebug/configure $(shell find 2>/dev/null $(PROJECTS)/libdebug -not \( -path $(PROJECTS)/libdebug/.git -prune \) -type f)'

  if ! grep -q 'CODEX_LIBDEBUG_AFTER_LIBGCC' "$makefile"; then
    perl -0pi -e 's@(# libdebug\n)@$1# CODEX_LIBDEBUG_AFTER_LIBGCC\n@' "$makefile"
  fi

  if ! grep -Fq '$(BUILD)/libdebug/Makefile: $(BUILD)/gcc/_libgcc_done' "$makefile"; then
    LIBDEBUG_DEPS_LINE="$deps_line" \
      perl -0pi -e 's@^\$\(BUILD\)/libdebug/Makefile:.*$@$ENV{LIBDEBUG_DEPS_LINE}@m' "$makefile"
  fi

  grep -Fq '$(BUILD)/libdebug/Makefile: $(BUILD)/gcc/_libgcc_done' "$makefile" \
    || die "failed to make libdebug wait for libgcc in ${makefile}"
}

patch_newlib_binutils_ordering() {
  local src="$1"
  local makefile="${src}/Makefile"
  local deps_line

  [[ -f "$makefile" ]] || return 0

  deps_line='$(BUILD)/newlib/newlib/libc.a: $(BUILD)/newlib/newlib/Makefile $(BUILD)/binutils/_gdb $(NEWLIB_FILES)'

  if ! grep -Fq '$(BUILD)/newlib/newlib/libc.a: $(BUILD)/newlib/newlib/Makefile $(BUILD)/binutils/_gdb' "$makefile"; then
    NEWLIB_DEPS_LINE="$deps_line" \
      perl -0pi -e 's@^\$\(BUILD\)/newlib/newlib/libc\.a:.*$@$ENV{NEWLIB_DEPS_LINE}@m' "$makefile"
  fi

  grep -Fq '$(BUILD)/newlib/newlib/libc.a: $(BUILD)/newlib/newlib/Makefile $(BUILD)/binutils/_gdb' "$makefile" \
    || die "failed to make newlib wait for binutils gdb in ${makefile}"
}

patch_zlib_download() {
  local src="$1"
  local makefile="${src}/Makefile"

  [[ -f "$makefile" ]] || die "missing source Makefile: ${makefile}"

  if grep -Fq 'https://zlib.net/$(ZLIB).tar.xz' "$makefile"; then
    log "Patching obsolete zlib download URL"
    perl -pi -e '
      s!\$\(ZLIB\)\.tar\.xz!\$\(ZLIB\).tar.gz!g;
      s!https://zlib\.net/\$\(ZLIB\)\.tar\.gz!https://zlib.net/fossils/\$\(ZLIB\).tar.gz!g;
    ' "$makefile"
  fi

  if grep -Fq 'https://zlib.net/$(ZLIB).tar.xz' "$makefile"; then
    die "failed to replace obsolete zlib download URL in ${makefile}"
  fi
}

apply_patch_file() {
  local dir="$1"
  local patch_file="$2"
  local reverse_output

  [[ -d "$dir" ]] || die "patch directory does not exist: ${dir}"
  [[ -f "$patch_file" ]] || die "missing patch file: ${patch_file}"

  if reverse_output="$(
    cd "$dir"
    "$PATCH_BIN" --reverse --force --dry-run --batch -p1 \
      -i "$patch_file" 2>&1
  )"; then
    case "$reverse_output" in
      *"Ignoring -R"*|*"Unreversed"*) ;;
      *)
        log "Patch already applied: ${patch_file}"
        return
        ;;
    esac
  fi

  if (
    cd "$dir"
    "$PATCH_BIN" --forward --dry-run --batch -p1 -i "$patch_file" >/dev/null 2>&1
    "$PATCH_BIN" --forward --batch -p1 -i "$patch_file"
  ); then
    return
  fi

  die "failed to apply patch: ${patch_file}"
}

patch_m68k_sibcall_prototype() {
  local src="$1"
  local header="${src}/projects/gcc/gcc/config/m68k/m68k.h"
  local declaration='extern bool m68k_is_ok_for_sibcall(tree decl, tree exp);'

  if grep -Fq "$declaration" "$header"; then
    log "Moving the m68k sibcall prototype out of the libgcc target header"
    apply_patch_file "$src/projects/gcc" \
      "${SCRIPT_DIR}/patches/gcc-m68k-sibcall-prototype.patch"
  fi

  if grep -Fq "$declaration" "$header"; then
    die "failed to move the m68k sibcall prototype out of ${header}"
  fi
}

configure_amiga_lto() {
  local src="$1"
  local makefile="${src}/Makefile"
  local enabled_line='CONFIG_BINUTILS += --enable-plugins'
  local disabled_line='# CODEX_AMIGA_LTO_DISABLED: CONFIG_BINUTILS += --enable-plugins'

  [[ -f "$makefile" ]] || die "missing source Makefile: ${makefile}"

  if [[ "$ENABLE_AMIGA_LTO" -eq 1 ]]; then
    log "Enabling Amiga HUNK LTO support"
    DISABLED_LINE="$disabled_line" ENABLED_LINE="$enabled_line" \
      perl -pi -e 's/^\Q$ENV{DISABLED_LINE}\E$/$ENV{ENABLED_LINE}/' "$makefile"
    grep -qE '^CONFIG_BINUTILS \+= --enable-plugins' "$makefile" \
      || die "binutils plugin support is not enabled in ${makefile}"
    return
  fi

  log "Disabling Amiga HUNK LTO support"
  DISABLED_LINE="$disabled_line" \
    perl -pi -e 's/^CONFIG_BINUTILS \+= --enable-plugins.*$/$ENV{DISABLED_LINE}/' "$makefile"
  if grep -qE '^CONFIG_BINUTILS \+= --enable-plugins' "$makefile"; then
    die "failed to disable binutils plugin support in ${makefile}"
  fi
}

verify_default_libstubs_archive() {
  local prefix="$1"
  local installed="${prefix}/m68k-amigaos/lib/libstubs.a"
  local ar="${prefix}/bin/m68k-amigaos-ar"
  local nm="${prefix}/bin/m68k-amigaos-nm"
  local first_member

  [[ -f "$installed" ]] || die "installed libstubs archive missing: ${installed}"
  if command -v file >/dev/null 2>&1; then
    if ! file "$installed" | grep 'AmigaOS object/library data' >/dev/null; then
      first_member="$("$ar" t "$installed" | sed -n '1p')"
      [[ -n "$first_member" ]] \
        || die "installed libstubs archive has no members: ${installed}"
      "$ar" p "$installed" "$first_member" | file - \
        | grep 'AmigaOS object/library data' >/dev/null \
        || die "installed libstubs archive has non-HUNK members: ${installed}"
    fi
  fi
  "$nm" "$installed" | grep ' _DOSBase$' >/dev/null \
    || die "installed libstubs archive does not expose _DOSBase"
}

make_amiga() {
  local src="$1"
  shift

  (
    cd "$src"
    "$MAKE_BIN" "$@" SHELL="$MAKE_SHELL"
  )
}

make_amiga_parallel() {
  local src="$1"
  shift

  (
    cd "$src"
    "$MAKE_BIN" -j "$JOBS" "$@" SHELL="$MAKE_SHELL"
  )
}

build_gcc_version() {
  local spec="$1"
  local version branch prefix src ndk zlib_build zlib_prefix

  version="$(version_from_spec "$spec")"
  branch="$(branch_from_spec "$spec")"
  [[ -n "$version" ]] || die "empty version in ${spec}"
  [[ -n "$branch" ]] || die "empty branch in ${spec}"
  ndk="$(ndk_for_version "$version")"

  if [[ -n "$PREFIX_OVERRIDE" ]]; then
    prefix="$PREFIX_OVERRIDE"
  else
    prefix="$(prefix_for_version "$version")"
  fi
  src="${WORKDIR}/amiga-gcc-${version}"
  zlib_build="${src}/build-$(uname -s)-m68k-amigaos-zlib"
  zlib_prefix="${prefix}/m68k-amigaos"

  log "Building GCC ${version} (${branch}) with NDK ${ndk}"
  ensure_prefix_writable "$prefix"
  install_amitools "$prefix"
  prepare_source "$version" "$src"

  log "Building and installing GCC ${version} into ${prefix}"
  make_amiga "$src" branch branch="$branch" mod=gcc
  patch_zlib_download "$src"
  make_amiga "$src" update NDK="$ndk" PREFIX="$prefix"
  patch_m68k_sibcall_prototype "$src"
  apply_patch_file "$src" \
    "${SCRIPT_DIR}/patches/amiga-gcc-zlib-68060.patch"
  patch_libdebug_ordering "$src"
  patch_newlib_binutils_ordering "$src"
  reset_variant_build_dir "$src" "$prefix"
  configure_amiga_lto "$src"
  make_amiga_parallel "$src" all NDK="$ndk" PREFIX="$prefix"

  # Upstream changed zlib from accepting the target prefix to appending
  # $(TARGET) itself. Support both layouts so dated and current source trees
  # install into the same final m68k-amigaos directories.
  if grep -Fq '$(PREFIX)/$(TARGET)/lib/libz.a' "${src}/Makefile"; then
    zlib_prefix="$prefix"
  fi
  log "Installing target zlib for GCC ${version}"
  make_amiga_parallel "$src" zlib NDK="$ndk" \
    BUILD="$zlib_build" \
    PREFIX="$zlib_prefix" \
    PATH="${prefix}/bin:${PATH}" \
    AR="${prefix}/bin/m68k-amigaos-ar" ARFLAGS=rcs \
    RANLIB="${prefix}/bin/m68k-amigaos-ranlib"
  verify_default_libstubs_archive "$prefix"

  log "Installing SDKs for GCC ${version}"
  make_amiga_parallel "$src" all-sdk NDK="$ndk" PREFIX="$prefix"
  "${SCRIPT_DIR}/install_flexcat.sh" "$prefix"

  download_and_fix_includes "$src" "$prefix"
  build_vlink_and_vbcc "$src" "$prefix" "$ndk"
  install_working_vbcc "$prefix"
  install_vbcc_configs "$prefix"
  install_gencrc "$prefix"
  verify_prefix "$prefix"
}

download_and_fix_includes() {
  local src="$1"
  local prefix="$2"
  local devices_dir="${prefix}/m68k-amigaos/ndk-include/devices"

  log "Downloading and fixing additional include files for ${prefix}"
  (
    cd "$src"
    curl -LfsS -o newstyle.h https://raw.githubusercontent.com/aros-development-team/AROS/master/compiler/include/devices/newstyle.h
    curl -LfsS -o sana2.h https://raw.githubusercontent.com/aros-development-team/AROS/master/compiler/include/devices/sana2.h
    curl -LfsS -o sana2specialstats.h https://raw.githubusercontent.com/aros-development-team/AROS/master/compiler/include/devices/sana2specialstats.h
    curl -LfsS -o newstyle.diff https://dl.amigadev.com/newstyle.diff
    if "$PATCH_BIN" --version 2>/dev/null | grep -qi 'GNU patch'; then
      "$PATCH_BIN" --ignore-whitespace < newstyle.diff
    else
      "$PATCH_BIN" -l < newstyle.diff
    fi
    mkdir -p "$devices_dir"
    mv -f newstyle.h sana2.h sana2specialstats.h "$devices_dir/"
  )
}

build_vlink_and_vbcc() {
  local src="$1"
  local prefix="$2"
  local ndk="$3"

  log "Building vlink and vbcc for ${prefix}"
  make_amiga_parallel "$src" vlink vbcc NDK="$ndk" PREFIX="$prefix"
}

install_working_vbcc() {
  local prefix="$1"
  local tmpdir="${WORKDIR}/vbcc-targets"
  local archive="${tmpdir}/vbcc_target_m68k-amigaos.lha"
  local extracted="${tmpdir}/vbcc_target_m68k-amigaos"

  log "Installing working VBCC target files into ${prefix}"
  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  curl -LfsS -o "$archive" http://phoenix.owl.de/vbcc/2022-05-22/vbcc_target_m68k-amigaos.lha
  (
    cd "$tmpdir"
    "${prefix}/bin/lha" -x "$(basename "$archive")"
  )

  [[ -d "${extracted}/targets" ]] || die "VBCC target archive did not extract targets/"
  mkdir -p "${prefix}/m68k-amigaos/vbcc"
  rm -rf "${prefix}/m68k-amigaos/vbcc/targets"
  mv "${extracted}/targets" "${prefix}/m68k-amigaos/vbcc/"
  rm -rf "$tmpdir"
}

install_vbcc_configs() {
  local prefix="$1"
  local config

  log "Installing VBCC config files with versioned paths into ${prefix}/bin"
  mkdir -p "${prefix}/bin"
  for config in aos68k aos68km aos68kr; do
    cp "${SCRIPT_DIR}/${config}" "${prefix}/bin/${config}"
  done

  PREFIX_REPLACEMENT="${prefix}/" perl -pi -e 's|/opt/amiga/|$ENV{PREFIX_REPLACEMENT}|g' \
    "${prefix}/bin/aos68k" \
    "${prefix}/bin/aos68km" \
    "${prefix}/bin/aos68kr"

  VBCC_INCLUDE="${prefix}/m68k-amigaos/vbcc/include" perl -pi -e 's|-Ivincludeos3:|-I$ENV{VBCC_INCLUDE}|g' \
    "${prefix}/bin/aos68k"
}

verify_prefix() {
  local prefix="$1"

  log "Verifying ${prefix}"
  if [[ -x "${prefix}/bin/m68k-amigaos-gcc" ]]; then
    "${prefix}/bin/m68k-amigaos-gcc" --version | head -n 1
  else
    die "missing compiler: ${prefix}/bin/m68k-amigaos-gcc"
  fi

  [[ -d "${prefix}/m68k-amigaos/vbcc/targets" ]] || die "missing VBCC targets in ${prefix}"
  [[ -f "${prefix}/bin/aos68k" ]] || die "missing VBCC config aos68k in ${prefix}"
  [[ -x "${prefix}/bin/gencrc" ]] || die "missing gencrc in ${prefix}"
  if [[ "$INSTALL_AMITOOLS" -eq 1 ]]; then
    [[ -x "${prefix}/bin/vamos" ]] || die "missing Vamos in ${prefix}"
    "${prefix}/bin/vamos" --help >/dev/null
  fi
}

link_default_prefix() {
  if [[ -z "$DEFAULT_SYMLINK_VERSION" ]]; then
    return
  fi

  local target
  if [[ -n "$PREFIX_OVERRIDE" ]]; then
    target="$PREFIX_OVERRIDE"
  else
    target="$(prefix_for_version "$DEFAULT_SYMLINK_VERSION")"
  fi
  [[ -d "$target" ]] || die "cannot link /opt/amiga; target does not exist: ${target}"

  case "$target" in
    /opt/*) ;;
    *) die "--link-default target must be under /opt: ${target}" ;;
  esac

  log "Linking /opt/amiga -> ${target}"
  if [[ "$(id -u)" -eq 0 ]]; then
    ln -sfn "$target" /opt/amiga
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo ln -sfn "$target" /opt/amiga
  else
    die "cannot update /opt/amiga without root or passwordless sudo"
  fi
}

main() {
  parse_args "$@"
  detect_jobs

  log "Using ${JOBS} parallel jobs"
  if [[ "$BUILD_HOST" == "mac" ]]; then
    ensure_brew
    configure_macos_tools
  else
    ensure_apt
    configure_linux_tools
  fi
  prepare_gencrc

  local spec
  for spec in "${VERSION_SPECS[@]}"; do
    build_gcc_version "$spec"
  done

  link_default_prefix
  log "Done"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
