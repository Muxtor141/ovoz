import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A small HTTP server inside the app, standing in for a content server: it
/// serves bundled assets with byte-range support and refuses requests without
/// the bearer token, like Mutolaa's API.
class LocalServer {
  LocalServer._(this._server);

  static const token = 'demo-token';

  final HttpServer _server;
  final _cache = <String, Uint8List>{};
  final requests = <String>[];

  /// When set, no byte at or past this offset of a file is sent: a request
  /// that reaches it gets the bytes before it and then nothing, its
  /// connection left open, as on a network that went quiet. Requests made
  /// after it is cleared are served in full.
  int? stallAt;
  final _closed = Completer<void>();

  Uri url(String asset) => Uri.parse('http://127.0.0.1:${_server.port}/$asset');

  static Future<LocalServer> start() async {
    final server = LocalServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    server._server.listen(server._handle);
    return server;
  }

  Future<void> close() {
    if (!_closed.isCompleted) _closed.complete();
    return _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    requests.add('${request.method} ${request.uri.path}${range == null ? '' : ' $range'}');
    if (request.headers.value(HttpHeaders.authorizationHeader) != 'Bearer $token') {
      response.statusCode = HttpStatus.unauthorized;
      return response.close();
    }

    final Uint8List body;
    try {
      body = _cache[request.uri.path] ??= (await rootBundle.load(
        'assets/audio${request.uri.path}',
      )).buffer.asUint8List();
    } on FlutterError {
      response.statusCode = HttpStatus.notFound;
      return response.close();
    }

    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentType = ContentType('audio', request.uri.path.endsWith('.mp3') ? 'mpeg' : 'mp4');
    var start = 0;
    var end = body.length - 1;
    final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range ?? '');
    if (match != null) {
      start = int.parse(match.group(1)!);
      if (match.group(2)!.isNotEmpty) end = int.parse(match.group(2)!).clamp(start, body.length - 1);
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${body.length}');
    }
    response.contentLength = end - start + 1;
    final limit = stallAt;
    if (limit != null && end >= limit) {
      if (request.method != 'HEAD' && start < limit) response.add(Uint8List.sublistView(body, start, limit));
      await response.flush();
      return _closed.future;
    }
    if (request.method != 'HEAD') response.add(Uint8List.sublistView(body, start, end + 1));
    await response.close();
  }
}
