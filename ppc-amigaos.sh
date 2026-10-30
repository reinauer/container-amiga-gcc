# shellcheck shell=bash
# ppc-amigaos (AmigaOS 4) toolchain steps for build.sh, which sources this
# file and provides log, die, MAKE_BIN, JOBS, WORKDIR and the other globals.
#
# Unlike m68k-amigaos there is no meta-Makefile: binutils and gcc come
# straight from the AmigaPorts branches, the newlib runtime from the
# AmigaOS SDK, and clib2 and clib4 are built with the new compiler, as
# adtools does.

PPC_TARGET="ppc-amigaos"
BINUTILS_REPO_URL="https://github.com/AmigaPorts/binutils-gdb"
LHA_REPO_URL="https://github.com/AmigaPorts/lha.git"
# clib2 as pinned by adtools; clib4 2.5, the first with gcc 15+ fixes.
CLIB2_REPO_URL="https://github.com/sodero/clib2.git"
CLIB2_REF="1a42c693e03881f6f969c43ab36ce20d2569751d"
CLIB4_REPO_URL="https://github.com/AmigaLabs/clib4.git"
CLIB4_REF="c640af22a7eea76260ac6ab631fb01ca96870576"

# AmigaPorts/gcc ref for a ppc-amigaos GCC version.
ppc_gcc_ref_for_version() {
  case "$1" in
    16.2) printf '%s\n' "amiga16.2" ;;
    *) die "no ppc-amigaos branch mapping for GCC version $1; use --version $1:REF" ;;
  esac
}

# AmigaPorts/binutils-gdb ref to pair with a ppc-amigaos GCC version.
ppc_binutils_ref_for_version() {
  case "$1" in
    16.2) printf '%s\n' "amiga-2.46" ;;
    *) die "no binutils mapping for GCC version $1; use --binutils-ref REF" ;;
  esac
}

# Check out REPO at REF (a branch, tag or commit) into DIR.
ppc_fetch_repo() {
  local repo="$1"
  local ref="$2"
  local dir="$3"

  if [[ "$REUSE_SOURCE" -eq 1 && -d "${dir}/.git" ]]; then
    log "Reusing source tree ${dir}"
    return
  fi

  safe_remove_source "$dir"
  log "Fetching ${repo} ${ref}"
  git init -q "$dir"
  git -C "$dir" remote add origin "$repo"
  git -C "$dir" fetch -q --depth 1 origin "$ref"
  git -C "$dir" checkout -q FETCH_HEAD
}

# The SDK is an lha archive that lhasa cannot fully unpack, so build the
# autoconf builds with -g -O2 when no flags are given, which makes the Linux
# executables (and the target libraries on any host) several times their
# size.  Leave out -g, as the m68k-amigaos build does.
PPC_HOST_FLAGS=(CFLAGS=-O2 CXXFLAGS=-O2)

# jca02266 lha port, from AmigaPorts' fork as the m68k build does: it
# carries the generated autotools files, so it needs no autoreconf.  It is
# installed into the prefix, as the m68k build does with its own lha.
ppc_install_lha() {
  local prefix="$1"
  local src="${WORKDIR}/lha"

  if [[ -x "${prefix}/bin/lha" ]]; then
    return
  fi

  ppc_fetch_repo "$LHA_REPO_URL" master "$src"
  log "Building lha"
  (
    cd "$src"
    ./configure --prefix="$prefix" "${PPC_HOST_FLAGS[@]}"
    "$MAKE_BIN" -j "$JOBS"
    "$MAKE_BIN" install
  )
}

# configure arguments for GMP, MPFR and MPC, which macOS keeps in Homebrew.
PPC_DEP_ARGS=()
ppc_set_dep_args() {
  PPC_DEP_ARGS=(--disable-werror)
  if [[ "$BUILD_HOST" == "mac" ]]; then
    PPC_DEP_ARGS+=(
      "--with-gmp=$(brew_prefix gmp)"
      "--with-mpfr=$(brew_prefix mpfr)"
    )
    if [[ "$1" == gcc ]]; then
      PPC_DEP_ARGS+=("--with-mpc=$(brew_prefix libmpc)")
    fi
  fi
}

ppc_build_binutils() {
  local src="$1"
  local prefix="$2"
  local build="${WORKDIR}/binutils-build"

  ppc_set_dep_args binutils
  log "Building binutils"
  safe_remove_source "$build"
  mkdir -p "$build"
  (
    cd "$build"
    "${src}/configure" --target="$PPC_TARGET" --prefix="$prefix" \
      --disable-nls --without-msgpack \
      --disable-gdb --disable-gdbserver --disable-sim --disable-gprofng \
      "${PPC_HOST_FLAGS[@]}" "${PPC_DEP_ARGS[@]}"
    "$MAKE_BIN" -j "$JOBS"
    "$MAKE_BIN" install
  )
}

ppc_sdk_archive() {
  local archive="${WORKDIR}/downloads/SDK_${SDK_VERSION}.lha"
  local file

  if [[ -n "$SDK_ARCHIVE" ]]; then
    [[ -f "$SDK_ARCHIVE" ]] || die "SDK archive not found: ${SDK_ARCHIVE}"
    printf '%s\n' "$SDK_ARCHIVE"
    return
  fi

  if [[ ! -f "$archive" ]]; then
    case "$SDK_VERSION" in
      54.16) file=127 ;;
      54.25) file=137 ;;
      *) die "no download URL known for SDK ${SDK_VERSION}; use --sdk-archive" ;;
    esac
    mkdir -p "$(dirname "$archive")"
    curl -LfsS -o "${archive}.tmp" \
      "https://www.hyperion-entertainment.com/index.php?option=com_registration&view=download&format=raw&file=${file}"
    mv "${archive}.tmp" "$archive"
  fi
  printf '%s\n' "$archive"
}

# The newlib runtime, base includes and exec SG from the SDK.
ppc_install_sdk() {
  local prefix="$1"
  local sdk="${prefix}/${PPC_TARGET}/SDK"
  local tmp="${WORKDIR}/sdk-extract"
  local archive

  archive="$(ppc_sdk_archive)"
  log "Installing AmigaOS SDK ${SDK_VERSION}"
  safe_remove_source "$tmp"
  mkdir -p "$tmp" "${sdk}/include"
  (
    cd "$tmp"
    lha xqf "$archive"
    cd SDK_Install
    lha xqf newlib*.lha
    lha xqf base.lha
    lha xqf execsg*.lha
    rm -f ./*.lha
    rm -rf "${sdk}/newlib" "${sdk}/include/"*
    mv newlib* "${sdk}/"
    mv Include/* "${sdk}/include/"
  )
  safe_remove_source "$tmp"
}

ppc_configure_gcc() {
  local src="$1"
  local build="$2"
  local prefix="$3"

  ppc_set_dep_args gcc
  safe_remove_source "$build"
  mkdir -p "$build"
  (
    cd "$build"
    "${src}/configure" --target="$PPC_TARGET" --prefix="$prefix" \
      --enable-languages=c,c++ \
      --enable-threads=amigaos --enable-lto \
      --with-dwarf2 --disable-tls --disable-libstdcxx-pch \
      --disable-c++tools --disable-nls --disable-bootstrap \
      "${PPC_HOST_FLAGS[@]}" \
      CFLAGS_FOR_TARGET=-O2 CXXFLAGS_FOR_TARGET=-O2 \
      "${PPC_DEP_ARGS[@]}"
  )
}

ppc_build_clib2() {
  local xgcc="$1"
  local prefix="$2"
  local src="${WORKDIR}/clib2"
  local sdk="${prefix}/${PPC_TARGET}/SDK"

  ppc_fetch_repo "$CLIB2_REPO_URL" "$CLIB2_REF" "$src"
  log "Building clib2"
  # clib2 predates C99's stricter rules, which gcc 14 and later enforce.
  "$MAKE_BIN" -C "${src}/library" -f GNUmakefile.os4 -j "$JOBS" \
    CC="${xgcc} -Wno-error=int-conversion -Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration" \
    AR="${prefix}/bin/${PPC_TARGET}-ar -q" \
    RANLIB="${prefix}/bin/${PPC_TARGET}-ranlib"
  rm -rf "${sdk}/clib2"
  mkdir -p "${sdk}/clib2"
  cp -Rp "${src}/library/include" "${src}/library/lib" "${sdk}/clib2/"
  cp "${src}/LICENSE" "${sdk}/clib2/"
}

ppc_build_clib4() {
  local xgcc="$1"
  local prefix="$2"
  local src="${WORKDIR}/clib4"
  local sdk="${prefix}/${PPC_TARGET}/SDK"

  ppc_fetch_repo "$CLIB4_REPO_URL" "$CLIB4_REF" "$src"
  log "Building clib4"
  "$MAKE_BIN" -C "$src" -f GNUmakefile.os4 -j "$JOBS" \
    CC="$xgcc" \
    AR="${prefix}/bin/${PPC_TARGET}-ar -q" \
    RANLIB="${prefix}/bin/${PPC_TARGET}-ranlib" \
    STRIP="${prefix}/bin/${PPC_TARGET}-strip" \
    INSTALL_PREFIX="${sdk}/clib4" \
    SDK_INCLUDE="${sdk}/include"
  rm -rf "${sdk}/clib4"
  mkdir -p "${sdk}/clib4/include" "${sdk}/clib4/lib"
  "$MAKE_BIN" -C "$src" -f GNUmakefile.os4 install INSTALL_PREFIX="${sdk}/clib4"
  cp "${src}"/LICENSE* "${sdk}/clib4/"
}

# Compile and link C and C++ programs against each C runtime.
ppc_verify_prefix() (
  local prefix="$1"
  local tmpdir crt

  log "Verifying ${prefix}"
  [[ -x "${prefix}/bin/${PPC_TARGET}-gcc" ]] \
    || die "missing compiler: ${prefix}/bin/${PPC_TARGET}-gcc"
  "${prefix}/bin/${PPC_TARGET}-gcc" --version | head -n 1
  [[ -x "${prefix}/bin/lha" ]] || die "missing lha in ${prefix}"

  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  # Each C runtime has to link C, and C++ with exceptions and threads.
  cat > "${tmpdir}/hello.c" <<'EOF'
#include <stdio.h>

int main(void)
{
    printf("Hello from ppc-amigaos-gcc\n");
    return 0;
}
EOF
  cat > "${tmpdir}/hello.cc" <<'EOF'
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>

static std::mutex mtx;

int main()
{
    try {
        throw std::runtime_error("exception");
    } catch (const std::exception &e) {
        std::cout << "caught " << e.what() << std::endl;
    }

    std::thread t([] {
        std::lock_guard<std::mutex> lock(mtx);
        std::cout << "Hello from a ppc-amigaos-g++ thread" << std::endl;
    });
    t.join();
    return 0;
}
EOF

  for crt in newlib clib2 clib4; do
    "${prefix}/bin/${PPC_TARGET}-gcc" -O2 -mcrt="$crt" \
      "${tmpdir}/hello.c" -o "${tmpdir}/hello-${crt}"
    "${prefix}/bin/${PPC_TARGET}-g++" -O2 -mcrt="$crt" -athread=native \
      "${tmpdir}/hello.cc" -o "${tmpdir}/hello-cc-${crt}"
    [[ -s "${tmpdir}/hello-${crt}" && -s "${tmpdir}/hello-cc-${crt}" ]] \
      || die "${crt} did not produce executables"
    printf '  %-7s ok\n' "$crt"
  done
)

build_ppc_version() {
  local spec="$1"
  local version gcc_ref binutils_ref prefix gcc_src binutils_src gcc_build xgcc

  version="$(version_from_spec "$spec")"
  gcc_ref="$(branch_from_spec "$spec")"
  binutils_ref="${BINUTILS_REF:-$(ppc_binutils_ref_for_version "$version")}"
  [[ -n "$version" ]] || die "empty version in ${spec}"

  if [[ -n "$PREFIX_OVERRIDE" ]]; then
    prefix="$PREFIX_OVERRIDE"
  else
    prefix="$(prefix_for_version "$version")"
  fi
  gcc_src="${WORKDIR}/ppc-gcc-${version}"
  binutils_src="${WORKDIR}/ppc-binutils-${version}"
  gcc_build="${WORKDIR}/ppc-gcc-${version}-build"

  log "Building ppc-amigaos GCC ${version} (gcc ${gcc_ref}, binutils ${binutils_ref}) with SDK ${SDK_VERSION}"
  ensure_prefix_writable "$prefix"
  ppc_fetch_repo "${BINUTILS_REPO_URL}.git" "$binutils_ref" "$binutils_src"
  ppc_fetch_repo "${GCC_REPO_URL}.git" "$gcc_ref" "$gcc_src"

  (
    export PATH="${prefix}/bin:${PATH}"
    # Under the amigaos thread model __gthread_cond_t is not a pthread
    # object, so libstdc++ must not use pthread_cond_clockwait() even where
    # the C library (clib4) has it.
    export glibcxx_cv_PTHREAD_COND_CLOCKWAIT=no

    ppc_install_lha "$prefix"
    ppc_build_binutils "$binutils_src" "$prefix"
    ppc_install_sdk "$prefix"

    ppc_configure_gcc "$gcc_src" "$gcc_build" "$prefix"
    log "Building the bootstrap compiler"
    "$MAKE_BIN" -C "$gcc_build" -j "$JOBS" all-gcc

    # clib2 and clib4 are built with the new compiler before its runtime
    # libraries, which need their headers.
    xgcc="${gcc_build}/gcc/xgcc -B${gcc_build}/gcc/"
    ppc_build_clib2 "$xgcc" "$prefix"
    ppc_build_clib4 "$xgcc" "$prefix"

    log "Building and installing GCC ${version} into ${prefix}"
    "$MAKE_BIN" -C "$gcc_build" -j "$JOBS"
    "$MAKE_BIN" -C "$gcc_build" install
  )

  ppc_verify_prefix "$prefix"
}
