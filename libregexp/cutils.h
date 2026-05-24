/*
 * C utilities - Minimal version for libregexp
 *
 * Copyright (c) 2017 Fabrice Bellard
 * Copyright (c) 2018 Charlie Gordon
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */
#ifndef CUTILS_H
#define CUTILS_H

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

#if defined(__APPLE__)
#include <malloc/malloc.h>
#elif defined(__linux__) || defined(__ANDROID__) || defined(__CYGWIN__)
#include <malloc.h>
#endif

#if defined(__sun)
#include <alloca.h>
#elif !defined(_MSC_VER)
#include <alloca.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define likely(x)       __builtin_expect(!!(x), 1)
#define unlikely(x)     __builtin_expect(!!(x), 0)
#define __maybe_unused __attribute__((unused))

#ifndef countof
#define countof(x) (sizeof(x) / sizeof((x)[0]))
#endif

/* Workaround for lack of vasprintf on some platforms */
#if defined(_MSC_VER)
#define JS_PRINTF_FORMAT_ATTR(f, a)
#elif defined(__GNUC__) || defined(__clang__)
#define JS_PRINTF_FORMAT_ATTR(f, a) __attribute__((format(printf, f, a)))
#else
#define JS_PRINTF_FORMAT_ATTR(f, a)
#endif

static inline int max_int(int a, int b) { return a > b ? a : b; }
static inline int min_int(int a, int b) { return a < b ? a : b; }

static inline uint32_t get_u8(const uint8_t *tab) { return *tab; }
static inline uint32_t get_u16(const uint8_t *tab) { uint16_t v; memcpy(&v, tab, sizeof(v)); return v; }
static inline uint32_t get_u32(const uint8_t *tab) { uint32_t v; memcpy(&v, tab, sizeof(v)); return v; }
static inline void put_u16(uint8_t *tab, uint16_t val) { memcpy(tab, &val, sizeof(val)); }
static inline void put_u32(uint8_t *tab, uint32_t val) { memcpy(tab, &val, sizeof(val)); }
static inline void put_u8(uint8_t *tab, uint8_t val) { *tab = val; }

static inline bool is_hi_surrogate(uint32_t c) { return (c >> 10) == (0xD800 >> 10); }
static inline bool is_lo_surrogate(uint32_t c) { return (c >> 10) == (0xDC00 >> 10); }
static inline uint32_t from_surrogate(uint32_t hi, uint32_t lo) { return 65536 + 1024 * (hi & 1023) + (lo & 1023); }

static inline int from_hex(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    else if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    else if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    else return -1;
}

/* UTF-8 decode */
#define UTF8_CHAR_LEN_MAX 4

static inline uint32_t utf8_decode(const uint8_t *p, const uint8_t **pp)
{
    uint32_t c; uint8_t lower, upper;
    c = *p++;
    if (c < 0x80) { *pp = p; return c; }
    switch (c) {
    case 0xC2: case 0xC3: case 0xC4: case 0xC5: case 0xC6: case 0xC7:
    case 0xC8: case 0xC9: case 0xCA: case 0xCB: case 0xCC: case 0xCD:
    case 0xCE: case 0xCF: case 0xD0: case 0xD1: case 0xD2: case 0xD3:
    case 0xD4: case 0xD5: case 0xD6: case 0xD7: case 0xD8: case 0xD9:
    case 0xDA: case 0xDB: case 0xDC: case 0xDD: case 0xDE: case 0xDF:
        if (*p >= 0x80 && *p <= 0xBF) { *pp = p + 1; return ((c - 0xC0) << 6) + (*p - 0x80); }
        break;
    case 0xE0: lower = 0xA0; goto need2;
    case 0xE1: case 0xE2: case 0xE3: case 0xE4: case 0xE5: case 0xE6: case 0xE7:
    case 0xE8: case 0xE9: case 0xEA: case 0xEB: case 0xEC: case 0xED: case 0xEE: case 0xEF:
        lower = 0x80;
    need2:
        if (*p >= lower && *p <= 0xBF && p[1] >= 0x80 && p[1] <= 0xBF) {
            *pp = p + 2; return ((c - 0xE0) << 12) + ((*p - 0x80) << 6) + (p[1] - 0x80);
        }
        break;
    case 0xF0: lower = 0x90; upper = 0xBF; goto need3;
    case 0xF4: lower = 0x80; upper = 0x8F; goto need3;
    case 0xF1: case 0xF2: case 0xF3: lower = 0x80; upper = 0xBF;
    need3:
        if (*p >= lower && *p <= upper && p[1] >= 0x80 && p[1] <= 0xBF && p[2] >= 0x80 && p[2] <= 0xBF) {
            *pp = p + 3; return ((c - 0xF0) << 18) + ((*p - 0x80) << 12) + ((p[1] - 0x80) << 6) + (p[2] - 0x80);
        }
        break;
    default: break;
    }
    *pp = p; return 0xFFFD;
}

static inline uint32_t utf8_decode_len(const uint8_t *p, size_t max_len, const uint8_t **pp)
{
    switch (max_len) {
    case 0: *pp = p; return 0xFFFD;
    case 1: if (*p < 0x80) goto good; break;
    case 2: if (*p < 0xE0) goto good; break;
    case 3: if (*p < 0xF0) goto good; break;
    default: good: return utf8_decode(p, pp);
    }
    *pp = p + 1; return 0xFFFD;
}

static inline size_t utf8_encode_len(uint32_t c)
{
    if (c < 0x80) return 1;
    if (c < 0x800) return 2;
    if (c < 0x10000) return 3;
    if (c < 0x110000) return 4;
    return 3;
}

static inline size_t utf8_encode(uint8_t buf[4], uint32_t c)
{
    if (c < 0x80) { buf[0] = c; return 1; }
    if (c < 0x800) { buf[0] = (c >> 6) | 0xC0; buf[1] = (c & 0x3F) | 0x80; return 2; }
    if (c < 0x10000) { buf[0] = (c >> 12) | 0xE0; buf[1] = ((c >> 6) & 0x3F) | 0x80; buf[2] = (c & 0x3F) | 0x80; return 3; }
    if (c < 0x110000) { buf[0] = (c >> 18) | 0xF0; buf[1] = ((c >> 12) & 0x3F) | 0x80; buf[2] = ((c >> 6) & 0x3F) | 0x80; buf[3] = (c & 0x3F) | 0x80; return 4; }
    buf[0] = (0xFFFD >> 12) | 0xE0; buf[1] = ((0xFFFD >> 6) & 0x3F) | 0x80; buf[2] = (0xFFFD & 0x3F) | 0x80; return 3;
}

static inline void js__pstrcpy(char *buf, int buf_size, const char *str)
{
    int c; char *q = buf;
    if (buf_size <= 0) return;
    for (;;) { c = *str++; if (c == 0 || q >= buf + buf_size - 1) break; *q++ = c; }
    *q = '\0';
}

/* DynBuf */
typedef void *DynBufReallocFunc(void *opaque, void *ptr, size_t size);

typedef struct DynBuf {
    uint8_t *buf;
    size_t size;
    size_t allocated_size;
    bool error;
    DynBufReallocFunc *realloc_func;
    void *opaque;
} DynBuf;

static void *dbuf_default_realloc(void *opaque, void *ptr, size_t size)
{
    if (size == 0) { free(ptr); return NULL; }
    return realloc(ptr, size);
}

static inline void dbuf_init2(DynBuf *s, void *opaque, DynBufReallocFunc *realloc_func)
{
    memset(s, 0, sizeof(*s));
    if (!realloc_func) realloc_func = dbuf_default_realloc;
    s->opaque = opaque;
    s->realloc_func = realloc_func;
}

static inline int dbuf_claim(DynBuf *s, size_t len)
{
    size_t new_size = s->size + len, new_allocated_size;
    uint8_t *new_buf;
    if (new_size < len) return -1;
    if (new_size > s->allocated_size) {
        if (s->error) return -1;
        new_allocated_size = s->allocated_size + (s->allocated_size / 2);
        if (new_allocated_size < new_size) new_allocated_size = new_size;
        new_buf = s->realloc_func(s->opaque, s->buf, new_allocated_size);
        if (!new_buf) { s->error = true; return -1; }
        s->buf = new_buf;
        s->allocated_size = new_allocated_size;
    }
    return 0;
}

static inline int dbuf_put(DynBuf *s, const void *data, size_t len)
{
    if (unlikely((s->size + len) > s->allocated_size))
        if (dbuf_claim(s, len)) return -1;
    if (len > 0) { memcpy(s->buf + s->size, data, len); s->size += len; }
    return 0;
}

static inline int dbuf_put_self(DynBuf *s, size_t offset, size_t len)
{
    if (unlikely((s->size + len) > s->allocated_size))
        if (dbuf_claim(s, len)) return -1;
    if (len > 0) { memcpy(s->buf + s->size, s->buf + offset, len); s->size += len; }
    return 0;
}

static inline int dbuf_putc(DynBuf *s, uint8_t val)
{
    if (unlikely((s->allocated_size - s->size) < 1)) {
        if (dbuf_put(s, &val, 1)) return -1;
        return 0;
    }
    s->buf[s->size++] = val;
    return 0;
}

static inline int dbuf_put_u16(DynBuf *s, uint16_t val)
{
    if (unlikely((s->allocated_size - s->size) < 2)) {
        if (dbuf_put(s, &val, 2)) return -1;
        return 0;
    }
    put_u16(s->buf + s->size, val);
    s->size += 2;
    return 0;
}

static inline int dbuf_put_u32(DynBuf *s, uint32_t val)
{
    if (unlikely((s->allocated_size - s->size) < 4)) {
        if (dbuf_put(s, &val, 4)) return -1;
        return 0;
    }
    put_u32(s->buf + s->size, val);
    s->size += 4;
    return 0;
}

static inline void dbuf_free(DynBuf *s)
{
    if (s->buf) { s->realloc_func(s->opaque, s->buf, 0); }
    memset(s, 0, sizeof(*s));
}

static inline bool dbuf_error(DynBuf *s) { return s->error; }

/* exchange and sort functions */

typedef void (*exchange_f)(void *a, void *b, size_t size);
typedef int (*cmp_f)(const void *, const void *, void *opaque);

static void exchange_bytes(void *a, void *b, size_t size) {
    uint8_t *ap = (uint8_t *)a, *bp = (uint8_t *)b;
    while (size--) { uint8_t t = *ap; *ap++ = *bp; *bp++ = t; }
}

static void exchange_one_byte(void *a, void *b, size_t size) {
    uint8_t *ap = (uint8_t *)a, *bp = (uint8_t *)b;
    uint8_t t = *ap; *ap = *bp; *bp = t;
}

static void exchange_int16s(void *a, void *b, size_t size) {
    uint16_t *ap = (uint16_t *)a, *bp = (uint16_t *)b;
    for (size /= sizeof(uint16_t); size--;) { uint16_t t = *ap; *ap++ = *bp; *bp++ = t; }
}

static void exchange_one_int16(void *a, void *b, size_t size) {
    uint16_t *ap = (uint16_t *)a, *bp = (uint16_t *)b;
    uint16_t t = *ap; *ap = *bp; *bp = t;
}

static void exchange_int32s(void *a, void *b, size_t size) {
    uint32_t *ap = (uint32_t *)a, *bp = (uint32_t *)b;
    for (size /= sizeof(uint32_t); size--;) { uint32_t t = *ap; *ap++ = *bp; *bp++ = t; }
}

static void exchange_one_int32(void *a, void *b, size_t size) {
    uint32_t *ap = (uint32_t *)a, *bp = (uint32_t *)b;
    uint32_t t = *ap; *ap = *bp; *bp = t;
}

static void exchange_int64s(void *a, void *b, size_t size) {
    uint64_t *ap = (uint64_t *)a, *bp = (uint64_t *)b;
    for (size /= sizeof(uint64_t); size--;) { uint64_t t = *ap; *ap++ = *bp; *bp++ = t; }
}

static void exchange_one_int64(void *a, void *b, size_t size) {
    uint64_t *ap = (uint64_t *)a, *bp = (uint64_t *)b;
    uint64_t t = *ap; *ap = *bp; *bp = t;
}

static void exchange_int128s(void *a, void *b, size_t size) {
    uint64_t *ap = (uint64_t *)a, *bp = (uint64_t *)b;
    for (size /= sizeof(uint64_t) * 2; size--; ap += 2, bp += 2) {
        uint64_t t = ap[0], u = ap[1]; ap[0] = bp[0]; ap[1] = bp[1]; bp[0] = t; bp[1] = u;
    }
}

static void exchange_one_int128(void *a, void *b, size_t size) {
    uint64_t *ap = (uint64_t *)a, *bp = (uint64_t *)b;
    uint64_t t = ap[0], u = ap[1]; ap[0] = bp[0]; ap[1] = bp[1]; bp[0] = t; bp[1] = u;
}

static inline exchange_f exchange_func(const void *base, size_t size) {
    switch (((uintptr_t)base | (uintptr_t)size) & 15) {
    case 0: return (size == sizeof(uint64_t) * 2) ? exchange_one_int128 : exchange_int128s;
    case 8: return (size == sizeof(uint64_t)) ? exchange_one_int64 : exchange_int64s;
    case 4: case 12: return (size == sizeof(uint32_t)) ? exchange_one_int32 : exchange_int32s;
    case 2: case 6: case 10: case 14: return (size == sizeof(uint16_t)) ? exchange_one_int16 : exchange_int16s;
    default: return (size == 1) ? exchange_one_byte : exchange_bytes;
    }
}

static void heapsortx(void *base, size_t nmemb, size_t size, cmp_f cmp, void *opaque)
{
    uint8_t *basep = (uint8_t *)base;
    size_t i, n, c, r;
    exchange_f swap = exchange_func(base, size);
    if (nmemb > 1) {
        i = (nmemb / 2) * size;
        n = nmemb * size;
        while (i > 0) {
            i -= size;
            for (r = i; (c = r * 2 + size) < n; r = c) {
                if (c < n - size && cmp(basep + c, basep + c + size, opaque) <= 0) c += size;
                if (cmp(basep + r, basep + c, opaque) > 0) break;
                swap(basep + r, basep + c, size);
            }
        }
        for (i = n - size; i > 0; i -= size) {
            swap(basep, basep + i, size);
            for (r = 0; (c = r * 2 + size) < i; r = c) {
                if (c < i - size && cmp(basep + c, basep + c + size, opaque) <= 0) c += size;
                if (cmp(basep + r, basep + c, opaque) > 0) break;
                swap(basep + r, basep + c, size);
            }
        }
    }
}

static inline void *med3(void *a, void *b, void *c, cmp_f cmp, void *opaque) {
    return cmp(a, b, opaque) < 0 ?
        (cmp(b, c, opaque) < 0 ? b : (cmp(a, c, opaque) < 0 ? c : a)) :
        (cmp(b, c, opaque) > 0 ? b : (cmp(a, c, opaque) < 0 ? a : c));
}

static inline void rqsort(void *base, size_t nmemb, size_t size, cmp_f cmp, void *opaque)
{
    struct { uint8_t *base; size_t count; int depth; } stack[50], *sp = stack;
    size_t m4, i, lt, gt, span, span2;
    int depth;
    uint8_t *ptr, *pi, *pj, *plt, *pgt, *top, *m;
    int c;
    exchange_f swap = exchange_func(base, size);
    exchange_f swap_block = exchange_func(base, size | 128);
    if (nmemb < 2 || size <= 0) return;
    sp->base = (uint8_t *)base; sp->count = nmemb; sp->depth = 0; sp++;
    while (sp > stack) {
        sp--; ptr = sp->base; nmemb = sp->count; depth = sp->depth;
        while (nmemb > 6) {
            if (++depth > 50) { heapsortx(ptr, nmemb, size, cmp, opaque); nmemb = 0; break; }
            m4 = (nmemb >> 2) * size;
            m = med3(ptr + m4, ptr + 2 * m4, ptr + 3 * m4, cmp, opaque);
            swap(ptr, m, size);
            i = lt = 1; pi = plt = ptr + size;
            gt = nmemb; pj = pgt = top = ptr + nmemb * size;
            for (;;) {
                while (pi < pj && (c = cmp(ptr, pi, opaque)) >= 0) {
                    if (c == 0) { swap(plt, pi, size); lt++; plt += size; }
                    i++; pi += size;
                }
                while (pi < (pj -= size) && (c = cmp(ptr, pj, opaque)) <= 0) {
                    if (c == 0) { gt--; pgt -= size; swap(pgt, pj, size); }
                }
                if (pi >= pj) break;
                swap(pi, pj, size); i++; pi += size;
            }
            span = plt - ptr; span2 = pi - plt; lt = i - lt;
            if (span > span2) span = span2;
            swap_block(ptr, pi - span, span);
            span = top - pgt; span2 = pgt - pi; pgt = top - span2; gt = nmemb - (gt - i);
            if (span > span2) span = span2;
            swap_block(pi, top - span, span);
            if (lt > nmemb - gt) {
                sp->base = ptr; sp->count = lt; sp->depth = depth; sp++;
                ptr = pgt; nmemb -= gt;
            } else {
                sp->base = pgt; sp->count = nmemb - gt; sp->depth = depth; sp++;
                nmemb = lt;
            }
        }
        for (pi = ptr + size, top = ptr + nmemb * size; pi < top; pi += size)
            for (pj = pi; pj > ptr && cmp(pj - size, pj, opaque) > 0; pj -= size)
                swap(pj, pj - size, size);
    }
}

#ifdef __cplusplus
}
#endif

#endif /* CUTILS_H */
