#!/usr/bin/env python3
"""Synthesizes the example app's audio, so every file in it is ours to ship.

Writes example/assets/audio/:
  chapter_{1,2,3}.m4a.enc  "audiobook chapters": a melody per chapter, AAC,
                           encrypted in Mutolaa's layout (AES-128-CTR)
  sample.mp3.enc           an MP3 encrypted the same way (Mutolaa's format)
  song_{a,b,c}.m4a         short melodies for the music queue
  gapless_{1,2}.m4a        one continuous chord split in two: any gap is audible
  rain_loop.m4a            noise bed for seamless looping
  click.wav, ding.wav      sound effects
and example/assets/images/cover.png, the lock-screen artwork.

Needs macOS (afconvert) and OpenSSL. sample.mp3 must already be there.
"""
import math
import os
import random
import struct
import subprocess
import wave
import zlib

OUT = os.path.join(os.path.dirname(__file__), '..', 'example', 'assets', 'audio')
RATE = 44100
# Demo key and IV (also in example/lib/demo_media.dart). Never a real one.
KEY = 'ovoz-demo-key-16'.encode().hex()
IV = 'ovoz-demo-iv--16'.encode().hex()


def write_wav(path, samples):
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b''.join(struct.pack('<h', max(-32767, min(32767, int(s * 32767)))) for s in samples))


def to_aac(wav, m4a, bitrate=96000):
    subprocess.run(['afconvert', '-f', 'm4af', '-d', 'aac', '-b', str(bitrate), wav, m4a], check=True)
    os.remove(wav)


def encrypt(src, dst):
    subprocess.run(['openssl', 'enc', '-aes-128-ctr', '-nosalt', '-K', KEY, '-iv', IV,
                    '-in', src, '-out', dst], check=True)


def note(freq, seconds, volume=0.25, decay=3.0):
    n = int(seconds * RATE)
    attack = int(0.01 * RATE)
    out = []
    for i in range(n):
        t = i / RATE
        env = min(1.0, i / attack) * math.exp(-decay * t)
        out.append(volume * env * (math.sin(2 * math.pi * freq * t) + 0.3 * math.sin(4 * math.pi * freq * t)))
    return out


def melody(root, pattern, beat, total_seconds):
    scale = [0, 2, 4, 7, 9, 12, 14, 16]
    samples = []
    i = 0
    while len(samples) < total_seconds * RATE:
        step = pattern[i % len(pattern)]
        freq = root * 2 ** (scale[step] / 12)
        samples += note(freq, beat)
        i += 1
    return samples[: int(total_seconds * RATE)]


def chord(freqs, seconds, volume=0.18):
    n = int(seconds * RATE)
    return [volume * sum(math.sin(2 * math.pi * f * i / RATE) for f in freqs) / len(freqs) for i in range(n)]


def write_cover(path, size=256):
    """A gradient square with a ring, as PNG, for the lock-screen artwork demo."""
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            dx, dy = x - size / 2, y - size / 2
            ring = abs(math.hypot(dx, dy) - size * 0.3) < size * 0.04
            r = int(40 + 120 * x / size)
            g = int(30 + 60 * y / size)
            b = int(120 + 100 * (1 - x / size))
            row += bytes((250, 240, 220) if ring else (r, g, b))
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)


def main():
    os.makedirs(OUT, exist_ok=True)
    images = os.path.join(OUT, '..', 'images')
    os.makedirs(images, exist_ok=True)
    write_cover(os.path.join(images, 'cover.png'))
    tmp = os.path.join(OUT, 'tmp.wav')

    # Audiobook chapters: long enough to scrub, short enough to finish in a test.
    for number, (root, pattern) in enumerate([(220.0, [0, 2, 4, 2]), (246.9, [0, 3, 5, 3, 1]),
                                              (196.0, [4, 2, 0, 1, 3])], start=1):
        write_wav(tmp, melody(root, pattern, 0.5, 40))
        plain = os.path.join(OUT, f'chapter_{number}.m4a')
        to_aac(tmp, plain, 64000)
        encrypt(plain, plain + '.enc')
        os.remove(plain)

    encrypt(os.path.join(OUT, 'sample.mp3'), os.path.join(OUT, 'sample.mp3.enc'))

    for name, root, pattern in [('a', 261.6, [0, 4, 2, 5]), ('b', 293.7, [5, 3, 1, 0, 2]),
                                ('c', 329.6, [0, 1, 2, 3, 4, 5])]:
        write_wav(tmp, melody(root, pattern, 0.25, 20))
        to_aac(tmp, os.path.join(OUT, f'song_{name}.m4a'), 128000)

    sustained = chord([261.6, 329.6, 392.0], 16)
    half = len(sustained) // 2
    for part, samples in ((1, sustained[:half]), (2, sustained[half:])):
        write_wav(tmp, samples)
        to_aac(tmp, os.path.join(OUT, f'gapless_{part}.m4a'), 128000)

    random.seed(7)
    rain, last = [], 0.0
    for _ in range(RATE * 6):
        last = 0.97 * last + 0.03 * random.uniform(-1, 1)
        rain.append(0.6 * last)
    fade = RATE // 10  # cross-fade the loop point so it is seamless
    for i in range(fade):
        w = i / fade
        rain[i] = rain[i] * w + rain[-fade + i] * (1 - w)
    write_wav(tmp, rain[:-fade])
    to_aac(tmp, os.path.join(OUT, 'rain_loop.m4a'), 96000)

    write_wav(os.path.join(OUT, 'click.wav'), note(1800, 0.05, 0.5, 60))
    write_wav(os.path.join(OUT, 'ding.wav'), note(880, 0.8, 0.35, 4))


if __name__ == '__main__':
    main()
