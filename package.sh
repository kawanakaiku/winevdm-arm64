#!/bin/sh
# Lay out the built files like upstream's tools/package.ps1 and zip them.
#   ./package.sh <name>     -> $OUT/<name>/ and $OUT/<name>.zip
# Environment: SRC (default ./winevdm), OUT (default ./out)
set -e
TOP=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$TOP/winevdm}
OUT=${OUT:-$TOP/out}
NAME=${1:-otvdm-arm64}
B=$OUT/build
DST=$OUT/$NAME
AS32=${AS32:-i686-w64-mingw32-clang -c -x assembler}
OBJCOPY=${OBJCOPY:-objcopy}

rm -rf "$DST" "$DST.zip"
mkdir -p "$DST/dll" "$DST/WINDOWS" "$DST/dummydll/SYSTEM" "$DST/dummydll/SYSTEM32"
for f in otvdm.exe otvdmw.exe winhlp32.exe libwine.dll; do cp "$B/$f" "$DST/"; done
cp "$SRC/otvdm.ini" "$SRC/LICENSE" "$SRC/install.inf" "$SRC/install.lnk" "$SRC/installw.inf" \
   "$SRC/install (no console).lnk" "$SRC/uninstall.reg" "$DST/"
cp "$SRC/README.md" "$DST/README.txt"
cp "$B"/*16 "$B/vm86.dll" "$B/wow32.dll" "$DST/dll/"
# drop the DWARF debug info (the COFF symbol table stays, for mapping crash addresses)
for f in "$DST"/*.exe "$DST"/*.dll "$DST"/dll/*; do ${STRIP:-llvm-strip} --strip-debug "$f"; done
: > "$DST/WINDOWS/WIN.INI"
: > "$DST/WINDOWS/SYSTEM.INI"

# 16-bit stub modules (the same bytes as the x86 build: they only hold the NE header and the entry table)
tmp=$(mktemp -d)
grep -o 'Make-Dll (Join-Path $root "[^"]*") "[^"]*" (Join-Path $dst "[^"]*")' "$SRC/tools/package.ps1" |
  sed 's/Make-Dll (Join-Path $root "\([^"]*\)") "\([^"]*\)" (Join-Path $dst "\([^"]*\)")/\1 \2 \3/' |
  while read -r spec name out; do
    "$OUT/host/convspec" "$SRC/$spec" "$name" -ver > "$tmp/m.s"
    $AS32 -o "$tmp/m.o" "$tmp/m.s"
    $OBJCOPY -O binary -j .data "$tmp/m.o" "$DST/$out"
  done
rm -rf "$tmp"
[ -f "$B/dummydll.dll" ] && cp "$B/dummydll.dll" "$DST/dummydll/SYSTEM/KRNL286.EXE"

( cd "$OUT" && zip -qr9 "$NAME.zip" "$NAME" )
echo "$OUT/$NAME.zip"
