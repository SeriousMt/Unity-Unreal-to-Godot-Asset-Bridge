// SPDX-License-Identifier: MIT (this file). The built ab-ooz binary links ooz and is GPL-3.0-or-later.
// ab-ooz: decompresses an Unreal Engine 5 FCompressedBuffer (as stored in a
// package trailer) using ooz's open-source Kraken/Mermaid/Selkie/Leviathan
// decoder. Built by build.sh; the resulting program is GPL-3.0-or-later
// because it links ooz.
//
//   ab-ooz [--undelta ROW_BYTES BYTES_PER_PIXEL CHANNEL_BYTES] <in.ucb> <out.bin>
//
// --undelta reverses UE's TSCF_UEDELTA texture source encoding (derived from
// real assets): the image is cut into strips of 8 * BYTES_PER_PIXEL rows; each
// strip's first row is stored as is, every other row as the difference to the
// row above -- byte-wise for 8-bit channels, as 16-bit values with a +0x8080
// bias for 16-bit channels.

#include "compat.h"

int Kraken_Decompress(const byte *src, size_t src_len, byte *dst, size_t dst_len);

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint64_t be64(const uint8_t *p) { return (uint64_t)be32(p) << 32 | be32(p + 4); }

static int fail(const char *msg) {
  fprintf(stderr, "ab-ooz: %s\n", msg);
  return 1;
}

int main(int argc, char **argv) {
  size_t undelta = 0, bpp = 4, channel_bytes = 1;
  if (argc == 7 && strcmp(argv[1], "--undelta") == 0) {
    undelta = (size_t)strtoull(argv[2], NULL, 10);
    bpp = (size_t)strtoull(argv[3], NULL, 10);
    channel_bytes = (size_t)strtoull(argv[4], NULL, 10);
    argv += 4;
    argc -= 4;
  }
  if (argc != 3) return fail("usage: ab-ooz [--undelta ROW_BYTES BPP CHANNEL_BYTES] <in> <out>");
  FILE *f = fopen(argv[1], "rb");
  if (!f) return fail("cannot open input");
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t *in = (uint8_t *)malloc(n > 0 ? n : 1);
  if (!in || fread(in, 1, n, f) != (size_t)n) return fail("cannot read input");
  fclose(f);

  // FHeader: magic, crc, method, compressor, level, block size exponent,
  // block count, raw size, compressed size, 32-byte BLAKE3 hash. Big-endian.
  const size_t header = 64;
  if (n < (long)header || be32(in) != 0xb7756362u) return fail("not an FCompressedBuffer");
  uint8_t method = in[8];
  uint32_t block_exp = in[11];
  uint32_t blocks = be32(in + 12);
  uint64_t raw_total = be64(in + 16);
  if (raw_total > (1ull << 34)) return fail("implausible size");
  uint8_t *out = (uint8_t *)malloc(raw_total + 64);
  if (!out) return fail("out of memory");

  if (method == 0) {  // stored
    if (header + raw_total > (uint64_t)n) return fail("truncated");
    memcpy(out, in + header, raw_total);
  } else {
    uint64_t block_raw = 1ull << block_exp;
    size_t table = header;
    size_t pos = header + (size_t)blocks * 4;
    uint64_t done = 0;
    for (uint32_t b = 0; b < blocks; b++) {
      if (table + 4 > (size_t)n) return fail("truncated block table");
      uint32_t csize = be32(in + table);
      table += 4;
      uint64_t rsize = raw_total - done < block_raw ? raw_total - done : block_raw;
      if (pos + csize > (size_t)n) return fail("truncated block");
      if (csize == rsize) {
        memcpy(out + done, in + pos, rsize);  // block stored uncompressed
      } else {
        int got = Kraken_Decompress(in + pos, csize, out + done, rsize);
        if (got != (int)rsize) return fail("decompression failed");
      }
      pos += csize;
      done += rsize;
    }
    if (done != raw_total) return fail("size mismatch");
  }
  if (undelta > 0) {
    const uint64_t strip = 8 * (bpp ? bpp : 4);
    uint64_t rows = raw_total / undelta;
    for (uint64_t y = 1; y < rows; y++) {
      if (y % strip == 0) continue;  // first row of a strip is stored raw
      uint8_t *row = out + y * undelta;
      const uint8_t *above = row - undelta;
      if (channel_bytes == 2) {
        for (uint64_t x = 0; x + 1 < undelta; x += 2) {
          uint16_t v = (uint16_t)(row[x] | row[x + 1] << 8);
          uint16_t u = (uint16_t)(above[x] | above[x + 1] << 8);
          uint16_t r = (uint16_t)(v + u - 0x8080);
          row[x] = (uint8_t)r;
          row[x + 1] = (uint8_t)(r >> 8);
        }
      } else {
        for (uint64_t x = 0; x < undelta; x++) row[x] = (uint8_t)(row[x] + above[x]);
      }
    }
  }
  FILE *o = fopen(argv[2], "wb");
  if (!o || fwrite(out, 1, raw_total, o) != raw_total) return fail("cannot write output");
  fclose(o);
  return 0;
}
