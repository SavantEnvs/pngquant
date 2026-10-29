#!/usr/bin/env bash
#
# mayhem/test.sh — RUN pngquant's functional suite (built by mayhem/build.sh): upstream's libimagequant C-API
# assertions (test/test.c) plus CLI checks ported from upstream test/test.sh, with known-answer assertions
# on the PNG pngquant writes (palette size, colour type, decoded pixels vs. the input).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

B="$SRC/build/test"
BIN="$B/pngquant"
IMG="$SRC/test/img"
[ -x "$BIN" ] && [ -x "$B/liq-api-test" ] || { echo "test binaries missing: run mayhem/build.sh" >&2; exit 2; }
WORK="$(mktemp -d -t pngquant-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

check() {  # check <name> <command...>
  local name="$1"; shift
  if "$@" >"$WORK/last.log" 2>&1; then PASS=$((PASS+1)); echo "ok   $name"
  else FAIL=$((FAIL+1)); echo "FAIL $name"; sed 's/^/     /' "$WORK/last.log" | head -20; fi
}

# png_info <file> <expect-colortype> <expect-w> <expect-h> <expect-plte-entries|-> [max-mean-err <orig>]
# Parses the PNG chunks itself; with an original, decodes both images and bounds the mean alpha-premultiplied RGBA error.
png_info() {
  python3 - "$@" <<'PY'
import struct, sys, zlib
def chunks(d):
    i = 8; assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    while i < len(d):
        n, = struct.unpack(">I", d[i:i+4]); yield d[i+4:i+8], d[i+8:i+8+n]; i += 12 + n
def load(path):
    d = open(path, "rb").read(); idat = b""; plte = trns = None
    for t, c in chunks(d):
        if t == b"IHDR": w, h, bd, ct = struct.unpack(">IIBB", c[:10])
        elif t == b"PLTE": plte = c
        elif t == b"tRNS": trns = c
        elif t == b"IDAT": idat += c
    ch = {6: 4, 3: 1, 2: 3}[ct]; bits = bd * ch; stride = (w * bits + 7) // 8; bpp = max(1, bits // 8)
    raw = zlib.decompress(idat); rows = []; prev = bytearray(stride); p = 0
    for _ in range(h):
        f = raw[p]; line = bytearray(raw[p+1:p+1+stride]); p += 1 + stride
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0; b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        rows.append(line); prev = line
    px = []
    for line in rows:
        for x in range(w):
            if ct == 6: px.append(tuple(line[4*x:4*x+4]))
            else:
                v = (line[x * bd // 8] >> (8 - bd - (x * bd) % 8)) & ((1 << bd) - 1) if bd < 8 else line[x]
                px.append((plte[3*v], plte[3*v+1], plte[3*v+2], trns[v] if trns and v < len(trns) else 255))
    return w, h, ct, (len(plte) // 3 if plte else None), px
args = sys.argv[1:]
w, h, ct, n, px = load(args[0])
assert ct == int(args[1]), f"colour type {ct} != {args[1]}"
assert (w, h) == (int(args[2]), int(args[3])), f"size {w}x{h}"
if args[4] != "-": assert n == int(args[4]), f"palette entries {n} != {args[4]}"
if len(args) > 5:
    ow, oh, _, _, opx = load(args[6])
    assert (ow, oh) == (w, h)
    pm = lambda q: (q[0] * q[3] / 255, q[1] * q[3] / 255, q[2] * q[3] / 255, q[3])
    err = sum(abs(x - y) for a, b in zip(px, opx) for x, y in zip(pm(a), pm(b))) / (4.0 * len(px))
    assert err < float(args[5]), f"mean error {err:.2f} >= {args[5]}"
PY
}

run_fails_with() {  # run_fails_with <exit-code> <cmd...>
  local want="$1"; shift
  "$@" >/dev/null 2>&1; local rc=$?
  [ "$rc" -eq "$want" ] || { echo "exit $rc, wanted $want: $*"; return 1; }
}

cp "$IMG/test.png" "$WORK/in.png"

check "libimagequant C API assertions (test/test.c)" bash -c "'$B/liq-api-test' | grep -qx OK"
check "--version prints a version number" bash -c "'$BIN' --version | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+'"
check "--help prints usage" bash -c "'$BIN' --help | grep -q 'usage:'"
check "no arguments is an error" run_fails_with 1 "$BIN"

check "16 colours: file written" bash -c "'$BIN' -o '$WORK/o16.png' 16 '$WORK/in.png' && test -f '$WORK/o16.png'"
check "16 colours: indexed PNG, 380x287, <=16 palette entries, pixels close to input" \
  bash -c "$(declare -f png_info); png_info '$WORK/o16.png' 3 380 287 - 6 '$WORK/in.png'"
check "256 colours: pixels very close to input" \
  bash -c "'$BIN' -o '$WORK/o256.png' 256 '$WORK/in.png' && $(declare -f png_info); png_info '$WORK/o256.png' 3 380 287 - 1.5 '$WORK/in.png'"
check "16 colours: output has exactly 16 palette entries" \
  bash -c "$(declare -f png_info); png_info '$WORK/o16.png' 3 380 287 16"
check "8 colours, no dithering: exactly 8 palette entries" \
  bash -c "'$BIN' --nofs -o '$WORK/o8.png' 8 '$WORK/in.png' && $(declare -f png_info); png_info '$WORK/o8.png' 3 380 287 8"
check "2 colours: exactly 2 palette entries" \
  bash -c "'$BIN' -o '$WORK/o2.png' 2 '$WORK/in.png' && $(declare -f png_info); png_info '$WORK/o2.png' 3 380 287 2"
check "default output name is <name>-fs8.png" bash -c "cd '$WORK' && cp in.png dflt.png && '$BIN' dflt.png && test -f dflt-fs8.png"
check "--nofs output name is <name>-or8.png" bash -c "cd '$WORK' && '$BIN' --nofs dflt.png && test -f dflt-or8.png"
check "refuses to overwrite without --force" run_fails_with 15 "$BIN" --ordered -o "$WORK/o16.png" "$WORK/in.png"
check "--force overwrites" bash -c "'$BIN' --force -o '$WORK/o16.png' 4 '$WORK/in.png' && $(declare -f png_info); png_info '$WORK/o16.png' 3 380 287 4"
check "quality floor above achievable exits 99 and writes nothing" \
  bash -c "rm -f '$WORK/skip.png'; '$BIN' -Q 100-100 -o '$WORK/skip.png' '$WORK/in.png'; [ \$? -eq 99 ] && [ ! -e '$WORK/skip.png' ]"
check "--skip-if-larger exits 98 and writes nothing" \
  bash -c "'$BIN' -Q 0-50 -o '$WORK/q50.png' '$WORK/in.png' && rm -f '$WORK/q49.png' && '$BIN' '$WORK/q50.png' --skip-if-larger -Q 0-49 -o '$WORK/q49.png'; [ \$? -eq 98 ] && [ ! -e '$WORK/q49.png' ]"
check "ancillary metadata chunk (XMP) is copied to the output" \
  bash -c "cp '$IMG/metadata.png' '$WORK/meta.png' && '$BIN' '$WORK/meta.png' && grep -aq '<rdf:RDF xmlns:rdf' '$WORK/meta-fs8.png'"
check "--strip drops the metadata chunk" \
  bash -c "'$BIN' --strip --force '$WORK/meta.png' && ! grep -aq '<rdf:RDF xmlns:rdf' '$WORK/meta-fs8.png'"
check "stdin to stdout pipeline produces an indexed PNG" \
  bash -c "'$BIN' 16 - < '$WORK/in.png' > '$WORK/stdout.png' && $(declare -f png_info); png_info '$WORK/stdout.png' 3 380 287 16"
check "a non-PNG input is rejected" bash -c "echo notapng > '$WORK/bad.png'; ! '$BIN' -o '$WORK/bad-out.png' '$WORK/bad.png' && [ ! -e '$WORK/bad-out.png' ]"

emit_ctrf "pngquant-cli+liq-api" "$PASS" "$FAIL" 0
