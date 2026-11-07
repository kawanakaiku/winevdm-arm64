#!/bin/sh
# Build winevdm (otvdm) for aarch64-windows with llvm-mingw.
#   ./build.sh            -> host tools + cmake configure + build
# Environment: SRC (default ./winevdm), OUT (default ./out)
set -e
TOP=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$TOP/winevdm}
OUT=${OUT:-$TOP/out}
HOST=$OUT/host
JOBS=${JOBS:-$(nproc)}
mkdir -p "$HOST/inc" "$HOST/widl"

# 1. build-machine tools (convspec, widl) from the winevdm sources
cp "$TOP/host/io.h" "$HOST/inc/io.h"
: > "$HOST/inc/process.h"
cc -O1 -w -D__i386__ -I"$HOST/inc" -I"$SRC/wine" -o "$HOST/convspec" "$SRC"/convspec/*.c
( cd "$HOST/widl"
  bison -p parser_ -d -o parser.tab.c "$SRC/widl/parser.y"
  flex -o parser.l.c "$SRC/widl/parser.l"
  bison -p ppy_ -d -o ppy.tab.c "$SRC/wpp/ppy.y"
  flex -o ppl.c "$SRC/wpp/ppl.l"
  cc -O1 -w -Wno-return-mismatch -DHAVE_GETOPT_H -I"$HOST/inc" -I"$SRC/wine" -I"$SRC/widl" -I"$SRC/wpp" -I. -I"$SRC/wine/windows" \
     "$SRC"/widl/client.c "$SRC"/widl/expr.c "$SRC"/widl/hash.c "$SRC"/widl/header.c "$SRC"/widl/proxy.c \
     "$SRC"/widl/register.c "$SRC"/widl/relay16.c "$SRC"/widl/server.c "$SRC"/widl/typegen.c "$SRC"/widl/typelib.c \
     "$SRC"/widl/typetree.c "$SRC"/widl/utils.c "$SRC"/widl/widl.c "$SRC"/widl/write_msft.c \
     "$SRC"/wpp/wpp.c "$SRC"/wpp/preproc.c parser.tab.c parser.l.c ppy.tab.c ppl.c -o "$HOST/widl.bin" )

# 2. cross build
cmake -S "$SRC" -DCMAKE_C_FLAGS="-ferror-limit=0" -DCMAKE_CXX_FLAGS="-ferror-limit=0" -B "$OUT/build" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$TOP/cmake/aarch64-w64-mingw32.cmake" \
  -DCMAKE_BUILD_TYPE=${BUILD_TYPE:-RelWithDebInfo} \
  -DHOST_CONVSPEC="$HOST/convspec" -DHOST_WIDL="$HOST/widl.bin"
cmake --build "$OUT/build" -j "$JOBS" -- -k 0
