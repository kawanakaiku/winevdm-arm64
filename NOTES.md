# winevdm (otvdm) を aarch64-windows に移す作業の記録

上流: https://github.com/otya128/winevdm の master `b88d7f87`。パッチは `patches/` (上流のクローンの枝 `arm64` を `git format-patch` で書き出したもの)。

## 方針

- 16 ビット側は今までどおり vm86.dll (MAME の i386 のコア) で動かす。ARM64 にするのは 32 ビット側 (krnl386・user・gdi などの C のコード) だけ。
- 16 ビットのコードから見える番地は 32 ビット (平らな番地) のまま使う。そのため、16 ビット側に渡る番地は全部 4GB より下に置く。
  - Wine の 64 ビットのプロセスは、preloader が無いとき 0x10000〜0x200000000 を予約し、下から確保する。ヒープ・スタック・VirtualAlloc は 4GB より下に入る。Hangover の Wine で、200MB を確保した後も 0x11D00040 だった。
  - lld は ARM64 の DLL と EXE に DYNAMIC_BASE を必ず付ける (`--no-dynamicbase` は効かない)。
    - Wine の server は、希望の基底が 4GB より下の DLL を、32 ビット用の ASLR の範囲 (0x7C000000 から下) に置く (`server/mapping.c` の assign_map_address)。
    - `CMakeLists.txt` の 16MB ごとの固定の基底は、ARM64 では使われない。
    - EXE は希望の 0x400000 に入る。
  - LDT の基底は 32 ビットなので、4GB より上の番地をセレクターにすると壊れる。
- lld は ARM64 の `.long 記号` (IMAGE_REL_ARM64_ADDR32) に再配置の記録を付けない。
  - 16 ビットのコードに埋める 32 ビットの番地は `.rva` (ADDR32NB) にし、krnl386 の patch_code_segment が DLL の基底を足す。
  - 全部のオブジェクトに plain の ADDR32 は 0 件 (DLL が置き直されても壊れない)。
- 例外は llvm-mingw の `__try` (aarch64 の mingw でも使える) を使う (`USE_COMPILER_EXCEPTIONS`)。下の「SEH」を参照。

## 型の決まり (64 ビットの時)

| もの | 決まり |
|---|---|
| 16 ビット側のレジスターの内容 | `CONTEXT86` (`wine/wine/context86.h`)。x86 では `CONTEXT`、64 ビットでは `WOW64_CONTEXT`。旗も `CONTEXT86_CONTROL` など |
| 16 ビットのコールバックの型 (`WNDPROC16`・`FARPROC16`・`DLGPROC16` …) | 中身は 16:16 なので `SEGPTR` (DWORD) |
| 16 ビットの構造体の `LPARAM`・`LRESULT` | `LPARAM16`・`LRESULT16` (LONG) |
| 16 ビットの構造体の中のポインター (中身は 16:16) | `#ifdef _WIN64` で `SEGPTR` |
| `ENTRYPOINT16.target`・`CALLFROM16.relay/glue`・`STACK16FRAME.frame32` | DWORD (4GB より下の平らな番地) |
| TDB | 並びを保つ。`teb` は後ろの未使用を使って 8 バイト、`hEvent` は `hEvent32` (DWORD) |
| 32 ビット側から呼ばれる thunk (x86 の機械語を書いていたもの) | `wine/wine/native_thunk.h` の `NATIVE_CLOSURE` (x0 に data を入れ、引数を 1 つずらして関数へ飛ぶ 10 命令) |
| 16 ビットのコードの中の x86 の機械語 (エミュレーターが読む) | そのまま。32 ビットの番地を埋めるなら 4GB より下 |
| セレクターの値 (`wine_get_cs` など) | x86 の WOW64 と同じ値 (cs 0x23、ds/es/ss/gs 0x2b、fs 0x53) |
| 32 ビットのハンドルを 32 ビットの値に | `HandleToULong`/`LongToHandle` (符号付きで広げる)。HWND は `HWND_16`/`HWND_32` |

## 16→32 と 32→16 の呼び出し

- convspec (`--arm64`) は、16 ビットのモジュールのバイト (NE の見出し・入り口の表・16 ビットの relay のコード) を x86 の版と同じに出す。違うのは、埋める番地が RVA になることだけ。
- 16 ビットの入り口の relay:
  - convspec が引数の型ごとの ARM64 の変換関数を作る (`.seh_*` 付き)。この関数が 16 ビットのスタックから引数を取り出し、AAPCS64 で本物の関数を呼ぶ。
  - krnl386 の `relay_call_from_16` は、ARM64 では `frame->relay` (この変換関数) を呼ぶ。
- 実行時に作る 16→32 の thunk (`make_thunk_32`) は、relay を `relay_call_from_16` にして、汎用の道 (`relay_get_args64` → `call_entry_point64`) を通す。
  - 引数は 1 つずつ別の整数レジスター (足りなければスタック) に入る。
  - `l` は符号付きで広げ、`p` は MapSL の 64 ビットの値。戻り値は x0 の下位 32 ビットを DX:AX に入れる。
- 32→16 (`WOWCallback16Ex`) は vm86 のエミュレーターに入る。

## SEH

- clang は ARM64 では同期の SEH しか扱わない。
  - `__try` の本体の中で直接 fault する読み書きは、try の範囲に入らない。
  - 呼び出しの無い本体では、`__except` ごと消される。
- `-Xclang -fasync-exceptions` なら直る。ただし vm86/msdos.cpp で clang が落ち、rmpatch/instr.c でアセンブラーが「value evaluated as 259 is out of range」で止まるので、使えない。
- そこで `wine/wine/exception.h` の `__TRY`・`__EXCEPT*`・`__FINALLY*` は、本体の両端で libwine の空の関数 `__wine_seh_barrier` を呼ぶ形にした。実機の probe で、O2 でも本体の中の fault を捕まえることを確かめた。
- 生の `__try` は調べ物用 (ADDR_TRACE・STACK_DUMP) か MSVC だけの所に残っている。
- task.c の NE_StartTask を包む `__try` は MSVC だけ。ARM64 では、タスクの中で捕まらなかった例外は Wine の既定の処理に行く。

## ビルド

```sh
./build.sh                             # 手元の道具 (convspec・widl) → CMake → ninja
cmake --build out/build -j16 -- -k 0   # 2 回目から
./package.sh otvdm-arm64               # 上流の package.ps1 と同じ並びの zip
```

- llvm-mingw (20260908、clang 23、ucrt) の `aarch64-w64-mingw32-clang`。
- `-Wint-conversion` (ポインターと整数の取り違え) と未宣言の関数は誤りのまま。同じ大きさのポインターの型の違いと void の return は警告に下げた。
- otvdm.exe・otvdmw.exe は、MSVC の版と同じく krnl386.exe16 と libwine.dll を遅延の読み込みにした (`dll/` を SetDllDirectoryW で足してから読むため)。
- llvm-mingw には ARM64 の libolecli32.a・libolesvr32.a が無いので、x86_64 の import lib の名前から作った .def を llvm-dlltool に通す。
- ダミーの 16 ビットのモジュール (`dummydll/SYSTEM`) は、convspec の `-ver` の出力を i686 の clang でアセンブルし、GNU objcopy で `.data` を抜き出す (llvm-objcopy は再配置のある節を抜き出せない)。
- 配る zip では `llvm-strip --strip-debug` で DWARF を落とす (COFF の記号表は残る)。

## 実行時に確かめる所 (コンパイルとリンクだけ通したもの)

- **4GB より下という前提に頼る所**:
  - mmsystem の MIDIHDR・WAVEHDR の `reserved` (32 ビット側のブロックの番地)
  - MCI の `MCI_AVI_SETVIDEO_DRAW_PROCEDURE`
  - `SetSelectorBase` に渡すバッファ (mmio16・msvideo16・gdi.c・wing.c)
  - WinHelp16 の `dwData`
  - OLE のインターフェースのオブジェクトと MapLS の領域
  - olecli32 のオブジェクトのポインター (OLEOBJ16)
  - LONG に切り詰める LHSERVER などのハンドル
- **user**:
  - WINPROC_THUNK はエミュレーターが実行するコードなので x86 のまま。64 ビットでは積む値を winproc の番号 (0xfffeXXXX) にし、本物の WNDPROC は別の表に置いた。
  - 16 ビットの DWL_DLGPROC などは、32 ビットの API の DWLP_* と分けた (`user_private.h` の `*16`)。
  - FormatMessage16 は、8 バイトずつの区画に広げた写し (最大 3 個) を va_list として渡す。
- **mmsystem の MCI**:
  - 64 ビットで `dwCallback` が 8 バイトになるので、一般のコマンドは幅広の写しにした。写す長さはコマンドごとの表 (`mci_generic_extra`) で推定している。
  - PLAY・SET・GETDEVCAPS・STATUS などを実機で試す必要がある。
- **OLE**:
  - widl の 16↔32 の relay は、値で渡す 8 バイトの構造体を DWORD 2 つで受ける。
  - float の引数 (`VarUI1FromR4`・`VarBstrFromR4`) は、ビットを読み替える `_conv` の入り口を通す。
  - `ITypeInfo_16_32_AddressOfMember` は 32 ビットの平らな番地をそのまま返す (元のまま)。
  - fnInvoke16 の BYREF の MapLS は解放しない (元のまま)。
- **krnl386**:
  - Throw16 (thunk.c の `__asm`) は ARM64 では未対応。
  - snoop は x86 のまま。
  - DOS の DTA の HANDLE は未対応。
- **x86 の動きも変えた上流の不具合の直し** (作業者が見つけたもの):
  - mmioSendMessage16 が thunk の代わりに SEGPTR を渡していた。
  - winnls の `lfQuality`。
  - rmpatch の FreeLibrary16。
  - winhlp32 の comp_TTLBTree の戻り値。
  - OLE の 8 件 (MAP_LPCRECTL32_16 の未初期化、HGLOBALStreamImpl16_CopyTo、IMalloc16 の QueryInterface、VectorFromBstr16 など)。

## Hangover での速さ (Xperia、x86 の otvdm v0.9.0 を box64 で動かす今の形との比べ)

各 3 回の平均。起動は、起動の命令から盤面の色の画素が出るまで。CPU は otvdm のプロセスの utime+stime を 30 秒間測ったもの。

| 項目 | ARM64 (この版) | x86 v0.9.0 (box64) |
|---|---|---|
| Rodent's Revenge の起動 | 2.47 秒 | 2.78 秒 |
| Rattler Race の起動 | 2.20 秒 | 2.65 秒 |
| Rodent の待ちの CPU | 0.5% | 0.7% |
| Rattler のデモ中の CPU | 6.6% | 9.3% |
| CPU だけを使う Win16 の繰り返し (約 3.9 億命令) の CPU 時間 | 3.1 秒 (約 127 MIPS) | 5.5 秒 (約 72 MIPS) |
| 同じ繰り返しの壁時計 (起動を含む) | 4.4 秒 | 6.9 秒 |

- 2 本のゲームは GDI で描くので、Wine の +fps のログ (ddraw・OpenGL・Vulkan だけ) が出ない。fps は測れていない。
- 繰り返しの EXE は、手で組んだ最小の NE (InitTask を呼ばず、int 21h の 4Ch で終わる)。
  - x86 の版は、この EXE の終わりで loader の lock と Win16Mutex の取り合いで止まる (上流の不具合)。ARM64 の版は終了コード 0 で終わる。
  - そのため、終わりは「CPU の時間の増えが止まった時」で決めた。
- DOS の .COM は、x86 の版も ARM64 の版も krnl386 の中で落ちる (低い番地への書き込み)。Hangover での元からの制限。

## 経過

- 11-07:
  - ビルドの仕組み、convspec の ARM64 の出力、CONTEXT86、16 ビットの構造体の型。
  - krnl386・vm86・libwine・otvdm のリンク。
  - user・gdi 系、mmsystem など、OLE 系を 3 つの作業者で並べて直し、全部のモジュールのリンクが通った。
  - Hangover の Wine (Xperia、Android の aarch64) で、krnl386 の起動、Rodent's Revenge と Rattler Race の起動と描画を確かめた。
  - otvdm の user32 なども遅延の読み込みにした (互換の旗のために自分をもう一度起動していた)。
  - v0.1.0 を Release に置いた。Hangover の Components と同じ入れ方 (NtVdm64 の登録、otvdmw.exe) でも 2 本が動いた。
  - x86 の版との速さの比べ (上の表)。
