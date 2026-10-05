// Proves the test vectors in ios/native_tests match Mutolaa's encryption, so
// the native tests that decrypt them prove the engine plays Mutolaa's files.
//
// Mutolaa decrypts with the `encrypt` package (PointyCastle): AES-CTR, the IV
// as a 128-bit big-endian counter, advanced by `offset ~/ 16` for a range read
// (packages/mutolaa_content_crypto/lib/src/decrypt_buffer.dart). The vectors
// were written by OpenSSL (tool/make_test_vectors.sh).
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixtures = 'ios/native_tests/Tests/OvozLoaderTests/Fixtures';

Uint8List _read(String name) => File('$_fixtures/$name').readAsBytesSync();

/// Mutolaa's `DecryptBuffer._counterAt`, verbatim in behaviour.
Uint8List _counterAt(Uint8List iv, int startByte) {
  final bytes = Uint8List.fromList(iv);
  var n = startByte ~/ 16;
  for (var i = bytes.length - 1; n != 0 && i >= 0; i--) {
    final tmp = bytes[i] + n;
    bytes[i] = 0xFF & tmp;
    n = tmp ~/ 0x100;
  }
  return bytes;
}

void main() {
  final plain = _read('sample.mp3');
  // Demo key and IV (tool/make_test_vectors.sh); the layout is Mutolaa's.
  final key = Key.fromUtf8('ovoz-demo-key-16');
  final iv = IV.fromUtf8('ovoz-demo-iv--16');
  final encrypter = Encrypter(AES(key, mode: AESMode.ctr, padding: null));

  test('the fixture is the file its checksum names', () {
    expect(sha256.convert(plain).toString(), File('$_fixtures/sample.mp3.sha256').readAsStringSync().trim());
  });

  test("Mutolaa's decryption reads the whole OpenSSL vector", () {
    final decrypted = encrypter.decryptBytes(Encrypted(_read('sample_separate_iv.mp3.enc')), iv: iv);
    expect(sha256.convert(decrypted), sha256.convert(plain));
  });

  test("Mutolaa's range decryption matches at random offsets", () {
    final cipher = _read('sample_separate_iv.mp3.enc');
    final random = Random(42);
    for (var i = 0; i < 200; i++) {
      final start = random.nextInt(cipher.length - 1);
      final end = min(cipher.length, start + 1 + random.nextInt(70000));
      final aligned = start - start % 16;
      final counter = IV(_counterAt(iv.bytes, aligned));
      final block = encrypter.decryptBytes(Encrypted(cipher.sublist(aligned, end)), iv: counter);
      expect(block.sublist(start - aligned), plain.sublist(start, end), reason: 'range $start-$end');
    }
  });

  test('the carry vector wraps the full 128-bit counter', () {
    final ones = IV(Uint8List.fromList(List.filled(16, 0xFF)));
    final decrypted = encrypter.decryptBytes(Encrypted(_read('sample_carry.mp3.enc')), iv: ones);
    expect(sha256.convert(decrypted), sha256.convert(plain));
  });

  test('the IV-in-header vector decrypts with AES-256', () {
    final file = _read('sample_ivheader.mp3.enc');
    final key256 = Key(Uint8List.fromList(List.generate(32, (i) => i)));
    final aes256 = Encrypter(AES(key256, mode: AESMode.ctr, padding: null));
    final decrypted = aes256.decryptBytes(Encrypted(file.sublist(16)), iv: IV(file.sublist(0, 16)));
    expect(sha256.convert(decrypted), sha256.convert(plain));
  });
}
