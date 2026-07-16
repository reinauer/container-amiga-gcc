#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/AmigaPorts/m68k-amigaos-gcc"
GCC_REPO_URL="https://github.com/AmigaPorts/gcc"
NDK_VERSION="3.2"
PREFIX_ROOT="/opt"
DATE_STAMP="${BUILD_DATE:-$(date +%Y%m%d)}"
PREFIX_TEMPLATE="amiga-v{version}-{date}"
WORKDIR="${SCRIPT_DIR}/.linux-build"
JOBS=""
INSTALL_APT=1
INSTALL_AMITOOLS=1
REUSE_SOURCE=0
DEFAULT_SYMLINK_VERSION=""
PREFIX_OVERRIDE=""
ENABLE_AMIGA_LTO=0
ENABLE_BEBBO_AMIGA6_PATCHES=0
HOST_CC="${CC:-}"
HOST_CXX="${CXX:-}"
VERSION_SPECS=()

SDKS=(
  filesysbox
  sdi
  ahi
  mhi
  camd
  cgx
  guigfx
  mui
  p96
  mcc_betterstring
  mcc_guigfx
  mcc_nlist
  mcc_texteditor
  mcc_thebar
  render
  warp3d
)

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
  lhasa
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

usage() {
  cat <<'EOF'
Usage: ./build_linux.sh [options]

Build Bebbo/AmigaPorts m68k-amigaos-gcc on Ubuntu Linux using the same high-level
steps as Containerfile.

Defaults:
  versions:       6.5.0b, 13.4, 16.1
  prefixes:       /opt/amiga-vVERSION-YYYYMMDD
  NDK:            3.2
  Amiga LTO:      enabled
  source workdir: ./.linux-build

Options:
  --ndk VERSION              NDK version passed to make (default: 3.2)
  --version VERSION[:BRANCH] Build one version; repeat for multiple versions
                             Known versions: 13.4 -> amiga13.4,
                             6.5.0b -> amiga6, 15.2 -> amiga15.2,
                             16.1 -> amiga16.1
  --prefix-root DIR          Install under DIR/TEMPLATE (default: /opt)
  --prefix DIR               Install a single requested version into DIR
  --prefix-template TEMPLATE Directory name under --prefix-root.
                             Supports {version} and {date}
                             (default: amiga-v{version}-{date})
  --date YYYYMMDD            Date stamp for the default prefix template
                             (default: today or BUILD_DATE)
  --workdir DIR              Build workspace (default: ./.linux-build)
  --jobs N                   Parallel make jobs (default: nproc)
  --repo URL                 Main amiga-gcc repository URL
  --cc PATH_OR_NAME          Host C compiler (default: prefer gcc-15/gcc)
  --cxx PATH_OR_NAME         Host C++ compiler (default: prefer g++-15/g++)
  --enable-amiga-lto         Apply experimental Amiga HUNK LTO patches and
                             build binutils with linker plugin support.
                             Supported for GCC 6.5.0b, 13.4, and 16.1.
  --enable-bebbo-amiga6-patches
                             Apply selected Bebbo amiga6 GCC backend and
                             optimizer patches on top of AmigaPorts/gcc
  --skip-apt                 Do not install missing Ubuntu packages
  --skip-amitools            Do not create a local amitools Python venv
  --reuse-source             Reuse existing per-version source trees
                             Generated build directories are reused only when
                             they match the requested prefix and patch modes
  --link-default VERSION     Create/update /opt/amiga -> the matching versioned prefix
  -h, --help                 Show this help

Examples:
  ./build_linux.sh
  ./build_linux.sh --date 20260518
  ./build_linux.sh --ndk 3.9 --version 13.4
  ./build_linux.sh --version 13.4 --prefix /opt/amiga-13.4-lto --enable-amiga-lto
  ./build_linux.sh --version 6.5.0b --enable-bebbo-amiga6-patches
  ./build_linux.sh --cc gcc-12 --cxx g++-12
  ./build_linux.sh --version 16.1 --prefix /opt/amiga-16.1-lto --enable-amiga-lto
  ./build_linux.sh --version 15.2:amiga15.2 --link-default 15.2
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

  JOBS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')"
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
      --enable-bebbo-amiga6-patches)
        ENABLE_BEBBO_AMIGA6_PATCHES=1
        shift
        ;;
      --skip-apt)
        INSTALL_APT=0
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
    VERSION_SPECS=("6.5.0b" "13.4" "16.1")
    ENABLE_AMIGA_LTO=1
  fi

  if [[ -n "$PREFIX_OVERRIDE" && ${#VERSION_SPECS[@]} -ne 1 ]]; then
    die "--prefix requires exactly one --version"
  fi

  if [[ "$ENABLE_AMIGA_LTO" -eq 1 ]]; then
    local lto_spec
    for lto_spec in "${VERSION_SPECS[@]}"; do
      case "${lto_spec%%:*}" in
        6.5.0b|13.4|16.1) ;;
        *) die "--enable-amiga-lto currently supports --version 6.5.0b, 13.4, or 16.1" ;;
      esac
    done
  fi

  if [[ "$ENABLE_AMIGA_LTO" -eq 1 && "$ENABLE_BEBBO_AMIGA6_PATCHES" -eq 1 ]]; then
    die "--enable-amiga-lto and --enable-bebbo-amiga6-patches cannot be combined"
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
    16.1) printf '%s\n' "amiga16.1" ;;
    *) die "no branch mapping for GCC version ${version}; use --version ${version}:BRANCH" ;;
  esac
}

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

ensure_apt() {
  if [[ "$INSTALL_APT" -eq 0 ]]; then
    log "Skipping Ubuntu package installation"
    return
  fi

  command -v dpkg-query >/dev/null 2>&1 || die "dpkg-query not found"
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found"

  local missing=()
  local package
  for package in "${APT_PACKAGES[@]}"; do
    if [[ "$package" == "lhasa" ]] && command -v lha >/dev/null 2>&1; then
      continue
    fi

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
  command -v lha >/dev/null 2>&1 || die "lha not found; install the lhasa package or rerun without --skip-apt"
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

  die "no GNU ${base} compiler found; install gcc/g++ or pass ${option}"
}

is_gnu_compiler() {
  local compiler="$1"
  local first_line

  first_line="$("$compiler" --version 2>/dev/null | head -n 1 || true)"
  [[ "$first_line" == *"GCC"* || "$first_line" == *"Free Software Foundation"* || "$first_line" == *"gcc"* || "$first_line" == *"g++"* ]]
}

verify_host_compiler() {
  local compiler="$1"
  local label="$2"
  local option="$3"

  command -v "$compiler" >/dev/null 2>&1 || die "${label} compiler not found: ${compiler}"
  is_gnu_compiler "$compiler" || die "${label} compiler is not GNU GCC: ${compiler}; pass ${option}"
}

ensure_amitools() {
  if [[ "$INSTALL_AMITOOLS" -eq 0 ]]; then
    log "Skipping amitools installation"
    return
  fi

  local venv="${WORKDIR}/venv"
  log "Installing amitools into ${venv}"
  mkdir -p "$WORKDIR"
  python3 -m venv "$venv"
  "${venv}/bin/python" -m pip install -U pip
  "${venv}/bin/python" -m pip install -U git+https://github.com/cnvogelg/amitools.git
  prepend_unique_path "${venv}/bin"
  export PATH
}

ensure_prefix_writable() {
  local prefix="$1"
  if [[ -d "$prefix" && -w "$prefix" ]]; then
    return
  fi

  log "Preparing writable prefix ${prefix}"
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
  local stamp="${build}/.build_linux_variant"
  local stamp_text

  [[ "$REUSE_SOURCE" -eq 1 ]] || return 0

  stamp_text="$(printf 'prefix=%s\nlto=%s\nbebbo_amiga6=%s' "$prefix" "$ENABLE_AMIGA_LTO" "$ENABLE_BEBBO_AMIGA6_PATCHES")"
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
  printf 'prefix=%s\nlto=%s\nbebbo_amiga6=%s\n' "$prefix" "$ENABLE_AMIGA_LTO" "$ENABLE_BEBBO_AMIGA6_PATCHES" > "$stamp"
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

patch_gcc15_libnix_sources() {
  local src="$1"
  local cmpxf2="${src}/projects/libnix/sources/math/math/__cmpxf2.c"

  if [[ -f "$cmpxf2" ]] && ! grep -q 'CODEX_GCC15_LIBNIX_TRUNCXFDF2' "$cmpxf2"; then
    log "Patching libnix __truncxfdf2 duplicate for GCC 15 libgcc"
    perl -0pi -e 's~(/\* convert long double to double \*/\ndouble\n__truncxfdf2)~#if !defined(__GNUC__) || __GNUC__ < 15\n#define CODEX_GCC15_LIBNIX_TRUNCXFDF2 1\n$1~' "$cmpxf2"
    perl -0pi -e 's~(\nextern int __cmpdf2 \(double x1, double x2\);)~\n#endif /* !defined(__GNUC__) || __GNUC__ < 15 */\n$1~' "$cmpxf2"
  fi
}

patch_libnix_findtooltype_sources() {
  local src="$1"
  local libnix_build="${src}/build-$(uname -s)-m68k-amigaos/libnix"

  log "Patching libnix FindToolType const-correctness"
  apply_patch_file "$src/projects/libnix" "${SCRIPT_DIR}/patches/libnix-findtooltype-const.patch"
  rm -f "${libnix_build}/_done"
}

patch_libnix_archive_sources() {
  local src="$1"
  local libnix_build="${src}/build-$(uname -s)-m68k-amigaos/libnix"

  log "Patching libnix archive target selection"
  apply_patch_file "$src/projects/libnix" "${SCRIPT_DIR}/patches/libnix-amigaos-ar-target.patch"
  rm -f "${libnix_build}/_done"
}

patch_libnix_link_sources() {
  local src="$1"
  local libnix_build="${src}/build-$(uname -s)-m68k-amigaos/libnix"

  log "Patching libnix4 linker plugin use"
  apply_patch_file "$src/projects/libnix" "${SCRIPT_DIR}/patches/libnix-libnix4-no-linker-plugin.patch"
  rm -f "${libnix_build}/_done" "${libnix_build}/libb/libnix4.library"
}

patch_amiga_statvfs_sources() {
  local src="$1"
  local build_dir="${src}/build-$(uname -s)-m68k-amigaos"
  local gcc_build="${build_dir}/gcc"

  log "Patching AmigaOS statvfs support"
  apply_patch_file "$src/projects/newlib-cygwin" "${SCRIPT_DIR}/patches/newlib-amigaos-statvfs.patch"
  apply_patch_file "$src/projects/libnix" "${SCRIPT_DIR}/patches/libnix-amigaos-statvfs.patch"

  rm -f "${build_dir}/newlib/_done" "${build_dir}/newlib/newlib/libc.a"
  rm -f "${build_dir}/libnix/_done"
  if [[ -d "$gcc_build" ]]; then
    find "$gcc_build" -name config.cache -type f -exec rm -f {} +
  fi
  rm -f "${gcc_build}/Makefile" "${gcc_build}/_done"
}

patch_filesysbox_statvfs_sources() {
  local src="$1"
  local filesysbox="${src}/projects/filesysbox"
  local build_filesysbox="${src}/build/filesysbox"

  if [[ ! -d "${filesysbox}/.git" ]]; then
    log "Cloning filesysbox SDK source"
    git clone --branch V54.7 --single-branch https://github.com/salass00/filesysbox "$filesysbox"
  fi

  log "Patching filesysbox statvfs prototype"
  apply_patch_file "$filesysbox" "${SCRIPT_DIR}/patches/filesysbox-statvfs-prototype.patch"

  if [[ -d "$build_filesysbox" ]]; then
    safe_remove_source "$build_filesysbox"
  fi
}

patch_gcc16_sources() {
  local src="$1"
  local gcc_build="${src}/build-$(uname -s)-m68k-amigaos/gcc"

  log "Patching GCC 16 m68k multiply cost overflow"
  apply_patch_file "$src/projects/gcc" "${SCRIPT_DIR}/patches/gcc16-m68k-mult-cost.patch"

  if [[ -d "$gcc_build" ]]; then
    find "$gcc_build" -name config.cache -type f -exec rm -f {} +
  fi
  rm -f "${gcc_build}/Makefile" "${gcc_build}/_done"
}

apply_patch_file() {
  local dir="$1"
  local patch_file="$2"
  local reverse_output

  [[ -d "$dir" ]] || die "patch directory does not exist: ${dir}"
  [[ -f "$patch_file" ]] || die "missing patch file: ${patch_file}"

  if reverse_output="$(
    cd "$dir"
    "$PATCH_BIN" --reverse --dry-run --batch -p1 -i "$patch_file" 2>&1
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

apply_patch_dir() {
  local dir="$1"
  local patch_dir="$2"
  local patch_file
  local marker="${dir}/.codex-$(basename "$patch_dir")-patches-applied"
  local found=0

  [[ -d "$patch_dir" ]] || die "patch directory does not exist: ${patch_dir}"

  if [[ -f "$marker" ]]; then
    log "Patch series already applied: ${patch_dir}"
    return
  fi

  while IFS= read -r patch_file; do
    found=1
    apply_patch_file "$dir" "$patch_file"
  done < <(find "$patch_dir" -maxdepth 1 -name '*.patch' -type f | sort)

  [[ "$found" -eq 1 ]] || die "no patch files found in ${patch_dir}"
  printf 'applied=%s\n' "$(basename "$patch_dir")" > "$marker"
}

patch_amiga_lto_sources() {
  local src="$1"
  local version="$2"
  local makefile="${src}/Makefile"
  local binutils_build="${src}/build-$(uname -s)-m68k-amigaos/binutils"
  local gcc_build="${src}/build-$(uname -s)-m68k-amigaos/gcc"
  local binutils_patch="${SCRIPT_DIR}/patches/amiga-lto-binutils.patch"
  local gcc_patch="${SCRIPT_DIR}/patches/amiga-lto-gcc.patch"

  log "Patching Amiga HUNK LTO support"
  if [[ "$version" == "6.5.0b" ]]; then
    gcc_patch="${SCRIPT_DIR}/patches/amiga-lto-gcc6.patch"
  fi
  apply_patch_file "$src/projects/binutils" "$binutils_patch"
  apply_patch_file "$src/projects/gcc" "$gcc_patch"

  if [[ -f "$makefile" ]] && ! grep -q 'CODEX_AMIGA_LTO_PLUGINS' "$makefile"; then
    perl -0pi -e 's@ifneq \(m68k-elf,\$\(TARGET\)\)\nCONFIG_BINUTILS \+= --disable-plugins\nendif\n@CONFIG_BINUTILS += --enable-plugins # CODEX_AMIGA_LTO_PLUGINS\n@' "$makefile"
  fi

  grep -q 'CODEX_AMIGA_LTO_PLUGINS' "$makefile" \
    || die "failed to enable binutils plugin support in ${makefile}"

  if [[ -d "$binutils_build" ]]; then
    find "$binutils_build" -name config.cache -type f -exec rm -f {} +
  fi
  if [[ -d "$gcc_build" ]]; then
    find "$gcc_build" -name config.cache -type f -exec rm -f {} +
  fi
  rm -f "${binutils_build}/Makefile" "${binutils_build}/_done"
  rm -f "${gcc_build}/Makefile" "${gcc_build}/_done"
}

verify_default_libstubs_archive() {
  local prefix="$1"
  local installed="${prefix}/m68k-amigaos/lib/libstubs.a"
  local nm="${prefix}/bin/m68k-amigaos-nm"

  [[ -f "$installed" ]] || die "installed libstubs archive missing: ${installed}"
  if command -v file >/dev/null 2>&1; then
    file "$installed" | grep 'AmigaOS object/library data' >/dev/null \
      || die "installed libstubs archive is not Amiga HUNK format: ${installed}"
  fi
  "$nm" "$installed" | grep ' _DOSBase$' >/dev/null \
    || die "installed libstubs archive does not expose _DOSBase"
}

patch_bebbo_amiga6_sources() {
  local src="$1"

  log "Patching selected Bebbo amiga6 GCC changes"
  apply_patch_dir "$src/projects/gcc" "${SCRIPT_DIR}/patches/bebbo-amiga6"
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
  local version branch prefix src sdk ndk

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

  log "Building GCC ${version} (${branch}) with NDK ${ndk}"
  ensure_prefix_writable "$prefix"
  prepare_source "$version" "$src"

  log "Building and installing GCC ${version} into ${prefix}"
  make_amiga "$src" branch branch="$branch" mod=gcc
  patch_zlib_download "$src"
  make_amiga "$src" update NDK="$ndk"
  patch_libdebug_ordering "$src"
  patch_newlib_binutils_ordering "$src"
  reset_variant_build_dir "$src" "$prefix"
  patch_libnix_findtooltype_sources "$src"
  patch_libnix_archive_sources "$src"
  patch_libnix_link_sources "$src"
  patch_amiga_statvfs_sources "$src"
  patch_gcc15_libnix_sources "$src"
  if [[ "$version" == "16.1" ]]; then
    patch_gcc16_sources "$src"
  fi
  if [[ "$ENABLE_BEBBO_AMIGA6_PATCHES" -eq 1 && "$branch" == "amiga6" ]]; then
    patch_bebbo_amiga6_sources "$src"
  fi
  if [[ "$ENABLE_AMIGA_LTO" -eq 1 ]]; then
    patch_amiga_lto_sources "$src" "$version"
  fi
  make_amiga_parallel "$src" all NDK="$ndk" PREFIX="$prefix"
  verify_default_libstubs_archive "$prefix"

  patch_filesysbox_statvfs_sources "$src"

  log "Installing SDKs for GCC ${version}"
  for sdk in "${SDKS[@]}"; do
    make_amiga_parallel "$src" "sdk=${sdk}" NDK="$ndk" PREFIX="$prefix"
  done
  make_amiga_parallel "$src" all-sdk NDK="$ndk" PREFIX="$prefix"

  download_and_fix_includes "$src" "$prefix"
  build_vlink_and_vbcc "$src" "$prefix" "$ndk"
  install_working_vbcc "$prefix"
  install_vbcc_configs "$prefix"
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
  (
    cd "$src"
    if ! grep -q '_POSIX_C_SOURCE=200809L' projects/vbcc/Makefile 2>/dev/null; then
      "$PATCH_BIN" -p1 < "${SCRIPT_DIR}/vbcc.diff"
    fi
  )
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
    lha -x "$(basename "$archive")"
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
}

link_default_prefix() {
  if [[ -z "$DEFAULT_SYMLINK_VERSION" ]]; then
    return
  fi

  local target
  target="$(prefix_for_version "$DEFAULT_SYMLINK_VERSION")"
  [[ -d "$target" ]] || die "cannot link /opt/amiga; target does not exist: ${target}"

  if [[ "$PREFIX_ROOT" != "/opt" ]]; then
    die "--link-default only manages /opt/amiga when --prefix-root is /opt"
  fi

  log "Linking /opt/amiga -> ${target}"
  sudo ln -sfn "$target" /opt/amiga
}

main() {
  parse_args "$@"

  [[ "$(uname -s)" == "Linux" ]] || die "build_linux.sh is intended for Linux"
  [[ -f "${SCRIPT_DIR}/vbcc.diff" ]] || die "missing ${SCRIPT_DIR}/vbcc.diff"
  detect_jobs

  log "Using ${JOBS} parallel jobs"
  ensure_apt
  configure_linux_tools
  ensure_amitools

  local spec
  for spec in "${VERSION_SPECS[@]}"; do
    build_gcc_version "$spec"
  done

  link_default_prefix
  log "Done"
}

main "$@"
