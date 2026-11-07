# winevdm-arm64

[otvdm (winevdm)](https://github.com/otya128/winevdm) を **aarch64-windows (ARM64)** 向けにビルドするための、パッチとワークフローの倉庫です。

- 主な使い道は、Android の [Hangover](https://github.com/AndreRH/hangover) 系の aarch64 の Wine の上で、Windows 3.x の 16 ビットのプログラムを動かすことです。
- x86 の otvdm を box64 で動かす代わりに、32 ビット側 (KERNEL・USER・GDI などを Win32 の API に橋渡しする部分) を ARM64 のネイティブのコードにします。
- 16 ビットのコードは、上流と同じ vm86.dll (MAME の i386 のエミュレーター) で実行します。

この倉庫にあるのはパッチとビルドの台本だけです。winevdm の本体は、GitHub Actions がビルドのたびに上流から取ってきます。

## 状態

- 上流の [`b88d7f87`](https://github.com/otya128/winevdm/commit/b88d7f8736d77baa5710eb0c35f81b489540c1a0) (v0.9.0 の後の master) に当てるパッチです。
- 全部のモジュールのビルドとリンクが通ります。
- Hangover の aarch64 の Wine (Xperia) で次の 2 本が起動し、画面が出ることを確かめました。
  - Rodent's Revenge (VBRUN100 を使う Visual Basic 1.0 のゲーム)
  - Rattler Race
- 試したのはまだこの範囲です。OLE・MCI・DDE・印刷・DOS などの経路は、コンパイルとリンクを通しただけで、実行では確かめていません。気付いた点は `NOTES.md` にあります。

## 使い方

[Releases](../../releases) の `otvdm-arm64-<版>.zip` が、上流の配布物と同じ並びになっています。

- 根: `otvdm.exe`・`otvdmw.exe`・`libwine.dll`・`otvdm.ini` など
- `dll/`: `*.exe16`・`*.dll16`・`*.drv16`・`vm86.dll`・`wow32.dll`
- `dummydll/`: 16 ビットのダミーのモジュール

上流の x86 の版と同じように、`otvdm.exe <16 ビットの EXE>` で動かします。

## ビルド

GitHub Actions (`.github/workflows/build.yml`) は次の手順で動きます。

1. Ubuntu の上に [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) 20260908 (ucrt) を入れる。
2. 上流の決まったコミットを取り、`patches/*.patch` を `git am --keep-cr` で当てる。
3. `build.sh` と `package.sh` を動かす。

`v*` のタグを push すると、zip とその sha256 を Release に置きます。

手元でビルドする場合:

```sh
git clone https://github.com/otya128/winevdm.git winevdm
git -C winevdm checkout b88d7f8736d77baa5710eb0c35f81b489540c1a0
git -C winevdm am --keep-cr "$PWD"/patches/*.patch
./build.sh                 # 手元の道具 (convspec・widl) → CMake → ninja。出力は out/build
./package.sh otvdm-arm64   # out/otvdm-arm64.zip
```

必要なもの:

- PATH に通った llvm-mingw (`aarch64-w64-mingw32-clang`・`i686-w64-mingw32-clang`・`llvm-dlltool`・`llvm-strip`)
- cmake・ninja・bison・flex・gcc (手元の道具用)・GNU objcopy (pe-i386 を扱えるもの)・zip

## しくみの要点

詳しくは `NOTES.md` を見てください。

- **16 ビット側から見える番地は 4GB より下**: 16 ビットのコードは 32 ビットの平らな番地を持つので、32 ビット側の関数や構造体を 4GB より下に置きます。
  - Wine の 64 ビットのプロセスは、下から確保します。
  - lld は ARM64 の DLL に必ず DYNAMIC_BASE を付けます。そのため Wine は DLL を 32 ビット用の ASLR の範囲 (0x7C000000 より下) へ置きます。
- **16 ビットのモジュールに埋める番地**: lld は ARM64 の 32 ビットの絶対番地 (ADDR32) に再配置の記録を付けません。そこで convspec は RVA を書き、krnl386 が読み込みの時に DLL の基底を足します。
- **16→32 の呼び出し**: convspec が引数の型ごとの ARM64 の入り口を作り、16 ビットのスタックから引数を取り出して AAPCS64 で呼びます。
- **32 ビット側から呼ばれる thunk**: x86 の機械語を書いていた所 (窓の手続き・タイマー・ダイアログの手続きなど) は、ARM64 の小さな closure (`wine/wine/native_thunk.h`) にしました。
- **16 ビットの構造体**: 64 ビットで大きさの変わる型 (ポインター・HANDLE・LPARAM …) を、SEGPTR・DWORD・LPARAM16 などに置き換えて、並びを保ちました。
- **SEH**: clang の ARM64 の SEH は同期の例外だけを扱います。そこで `__TRY` の本体の両端で不透明な関数を呼び、本体の中の fault も捕まえるようにしました。

## ライセンス

パッチは上流の winevdm と同じ条件 (GPL-2.0。Wine に由来する部分は LGPL-2.1 以降) で配ります。`LICENSE` を見てください。ビルドの台本 (`build.sh`・`package.sh`・ワークフローなど) も同じ条件です。
