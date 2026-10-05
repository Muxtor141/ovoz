#!/usr/bin/env bash
# Builds the encrypted test vectors used by the native tests (ios/native_tests)
# and the Dart cross-implementation test (test/cross_implementation_test.dart).
#
# OpenSSL's AES-CTR treats the IV as one 128-bit big-endian counter, like
# PointyCastle (the `encrypt` package Mutolaa encrypts with). The Dart test
# proves that for these files; the native tests then prove the engine agrees.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=ios/native_tests/Tests/OvozLoaderTests/Fixtures
mkdir -p "$OUT"
SRC=${SAMPLE_MP3:-example/assets/audio/sample.mp3}
cp "$SRC" "$OUT/sample.mp3"

hex() { printf '%s' "$1" | xxd -p | tr -d '\n'; }

# Demo keys only. Never put a real content key in this repository.
#
# 1. Mutolaa's layout: AES-128, the IV passed separately, no header.
KEY128=$(hex 'ovoz-demo-key-16')
IV=$(hex 'ovoz-demo-iv--16')
openssl enc -aes-128-ctr -nosalt -K "$KEY128" -iv "$IV" -in "$OUT/sample.mp3" -out "$OUT/sample_separate_iv.mp3.enc"

# 2. AES-256 with the IV stored as the file's first 16 bytes.
KEY256=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
IVH=f0e1d2c3b4a5968778695a4b3c2d1e0f
{ printf '%s' "$IVH" | xxd -r -p; openssl enc -aes-256-ctr -nosalt -K "$KEY256" -iv "$IVH" -in "$OUT/sample.mp3"; } > "$OUT/sample_ivheader.mp3.enc"

# 3. Counter carry: an all-ones IV wraps the whole 128-bit counter after the
#    first block, which a 64-bit (or 32-bit) counter would get wrong.
openssl enc -aes-128-ctr -nosalt -K "$KEY128" -iv ffffffffffffffffffffffffffffffff -in "$OUT/sample.mp3" -out "$OUT/sample_carry.mp3.enc"

shasum -a 256 "$OUT/sample.mp3" | cut -d' ' -f1 > "$OUT/sample.mp3.sha256"
ls -l "$OUT"
