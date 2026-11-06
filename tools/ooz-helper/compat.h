// Linux/GCC/Clang replacement for ooz's Windows-only stdafx.h.
// SPDX-License-Identifier: MIT (this file). The built ab-ooz binary links ooz and is GPL-3.0-or-later.
#pragma once

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <x86intrin.h>

#define _CRT_SECURE_NO_WARNINGS 1
#define __forceinline inline __attribute__((always_inline))

typedef unsigned char byte;
typedef unsigned char uint8;
typedef unsigned int uint32;
typedef uint64_t uint64;
typedef int64_t int64;
typedef signed int int32;
typedef unsigned short uint16;
typedef signed short int16;
typedef unsigned int uint;

template <typename T>
static inline unsigned char _BitScanReverse(T *index, uint32_t mask) {
  if (!mask) return 0;
  *index = (T)(31 - __builtin_clz(mask));
  return 1;
}

template <typename T>
static inline unsigned char _BitScanForward(T *index, uint32_t mask) {
  if (!mask) return 0;
  *index = (T)__builtin_ctz(mask);
  return 1;
}

#define _byteswap_ushort(x) __builtin_bswap16(x)
#define _byteswap_ulong(x) __builtin_bswap32(x)
#define _byteswap_uint64(x) __builtin_bswap64(x)

#ifndef _rotl
static inline uint32_t _rotl(uint32_t v, int s) { return (v << (s & 31)) | (v >> ((32 - s) & 31)); }
#endif
