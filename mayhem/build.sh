#!/usr/bin/env bash
#
# mayhem/build.sh — build pngquant's fuzz harness (sanitized), its standalone reproducer, and the
# project's own test suite (normal flags). Runs in the commit image as `mayhem` in /mayhem.
#
# pngquant is C (rwpng.c, pngquant.c) on top of libpng and libimagequant. libimagequant is the `lib/`
# git submodule and is a Rust crate with a C ABI (imagequant-sys); it is built with the in-image Rust
# toolchain (/opt/toolchains/rust) and linked as a static library. libpng comes from the pinned
# tarball in /opt/deps and is built here so the fuzzed libpng is sanitized and coverage-instrumented.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
B="$SRC/build"            # gitignored by upstream's .gitignore ("build")
LIQ="$SRC/lib"
mkdir -p "$B"

# --- libimagequant (Rust, C ABI) -------------------------------------------------------------
# lib/ has no Cargo.lock (it is gitignored upstream); seed it from the committed one so the
# dependency closure is the one cached in the image.
if [ ! -f "$LIQ/Cargo.lock" ]; then
  cp "$SRC/mayhem/libimagequant.Cargo.lock" "$LIQ/Cargo.lock"
fi
if [ ! -f "$B/libimagequant_sys.a" ]; then
  CARGO_TARGET_DIR="$B/cargo-target" \
    cargo build --release --manifest-path "$LIQ/imagequant-sys/Cargo.toml" -j "$MAYHEM_JOBS"
  cp "$B/cargo-target/release/libimagequant_sys.a" "$B/libimagequant_sys.a"
  # Rust's precompiled std carries DWARF 4 line info; the contract is DWARF <= 3 for the whole binary.
  llvm-objcopy --strip-debug "$B/libimagequant_sys.a"
fi
LIQ_INC="-I$LIQ -I$LIQ/imagequant-sys"
LIQ_LIBS="$B/libimagequant_sys.a -lpthread -ldl -lm"

# --- libpng, built three ways: coverage+sanitizer (fuzzer), sanitizer only (standalone), plain (tests)
build_libpng() {  # <name> <cflags...>
  local name="$1"; shift
  local prefix="$B/libpng-$name"
  [ -f "$prefix/lib/libpng16.a" ] && return 0
  rm -rf "$B/libpng-src-$name" && mkdir -p "$B/libpng-src-$name"
  tar -xJf /opt/deps/libpng.tar.xz -C "$B/libpng-src-$name" --strip-components=1
  ( cd "$B/libpng-src-$name"
    { env -u CFLAGS -u LDFLAGS ./configure --prefix="$prefix" --disable-shared --enable-static \
          --disable-tests --disable-tools CC="$CC" CFLAGS="$*" \
      && make -j"$MAYHEM_JOBS" && make install; } >"$B/libpng-$name.log" 2>&1 \
      || { tail -50 "$B/libpng-$name.log" >&2; exit 1; } )
  rm -rf "$B/libpng-src-$name"
}
build_libpng fuzz -O1 $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS
build_libpng standalone -O1 $SANITIZER_FLAGS $DEBUG_FLAGS
build_libpng test -O2 $COVERAGE_FLAGS

# --- fuzz harness: rwpng.c (the project's PNG reader/writer) + harness + libpng + libimagequant --
COMMON_DEFS="-DUSE_SSE=1 -DNDEBUG=1"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 $COMMON_DEFS -c "$SRC/mayhem/lsan_off.c" -o "$B/lsan_off.o"

$CC $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1 $COMMON_DEFS $LIQ_INC \
    -I"$B/libpng-fuzz/include" -c "$SRC/rwpng.c" -o "$B/rwpng-fuzz.o"
$CC $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $DEBUG_FLAGS -O1 $LIQ_INC -I"$SRC" -I"$B/libpng-fuzz/include" \
    "$SRC/mayhem/pngquant_fuzz.c" "$B/rwpng-fuzz.o" "$B/lsan_off.o" \
    "$B/libpng-fuzz/lib/libpng16.a" $LIQ_LIBS -lz -o /mayhem/pngquant-fuzz

# --- standalone reproducer (run-once driver, no libFuzzer runtime) ---------------------------
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 $COMMON_DEFS $LIQ_INC -I"$B/libpng-standalone/include" \
    -c "$SRC/rwpng.c" -o "$B/rwpng-standalone.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 $LIQ_INC -I"$SRC" -I"$B/libpng-standalone/include" \
    "$STANDALONE_FUZZ_MAIN" "$SRC/mayhem/pngquant_fuzz.c" "$B/rwpng-standalone.o" "$B/lsan_off.o" \
    "$B/libpng-standalone/lib/libpng16.a" $LIQ_LIBS -lz -o /mayhem/pngquant-fuzz-standalone

# --- test suite, normal flags: the real pngquant CLI + upstream's libimagequant C API tests ----
mkdir -p "$B/test"
$CC -O2 $COVERAGE_FLAGS $COMMON_DEFS $LIQ_INC -I"$B/libpng-test/include" \
    "$SRC/pngquant.c" "$SRC/rwpng.c" "$SRC/pngquant_opts.c" \
    "$B/libpng-test/lib/libpng16.a" $LIQ_LIBS -lz -o "$B/test/pngquant"
$CC -O2 $COVERAGE_FLAGS $LIQ_INC "$SRC/test/test.c" $LIQ_LIBS -o "$B/test/liq-api-test"
