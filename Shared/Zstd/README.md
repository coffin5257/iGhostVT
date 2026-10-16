# Vendored zstd

Zstandard 1.5.7 (`facebook/zstd`, release tarball SHA-256
`eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`), used
by `ighostvt-cli drop` to compress what it puts on the relay and to decode
what it takes. Only the CLI compiles it; the app and the daemons never link
it. zstd is dual-licensed BSD / GPLv2; this project takes it under the BSD
license, which is the text in `Licenses/zstd/` and the only one shipped.

- `zstd.h`, `zstd_errors.h` — `lib/` of the release, unchanged.
- `zstd.c` — one file made by the release's own amalgamation script,
  `build/single_file_libs/combine.py`, from its `zstd-in.c` with the
  dictionary builder, the multithreaded compressor and its thread pool taken
  out (`ZSTD_MULTITHREAD` undefined): the CLI compresses on one thread, which
  is also what makes a resumed upload's stream byte for byte the first one.

To update, unpack a release and run, from this folder:

```sh
sed -e '/^#ifndef __EMSCRIPTEN__/,/^#endif/d' -e '/dictBuilder/d' \
    -e '/zstdmt_compress.c/d' -e '/common\/threading.c/d' -e '/common\/pool.c/d' \
    <zstd>/build/single_file_libs/zstd-in.c > /tmp/zstd-in.c
python3 -I <zstd>/build/single_file_libs/combine.py -r <zstd>/lib \
    -x legacy/zstd_legacy.h -o zstd.c /tmp/zstd-in.c
cp <zstd>/lib/zstd.h <zstd>/lib/zstd_errors.h .
```

then the new `LICENSE` into `Licenses/zstd/` and the version into its
`notice.json`. A new release changes the bytes a level produces, so an
upload cut off under the old CLI restarts from the beginning under the new
one; nothing else notices.
