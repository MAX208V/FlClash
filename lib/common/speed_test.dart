import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/state.dart';

/// Downloads a file through the Clash proxy and returns the measured speed
/// in Mbps (megabits per second).
class SpeedTest {
  /// 测带宽：[connectTimeout] 控制连通性超时，[totalTimeout] 控制整个
  /// 单节点测速的总时间上限。当总时间超时，会取消下载并抛出 [TimeoutException]。
  Future<double> testDownload(
    String url, {
    Duration connectTimeout = const Duration(seconds: 10),
    Duration? totalTimeout,
    CancelToken? cancelToken,
  }) async {
    final dio = Dio();
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (Uri uri) {
          client.userAgent = globalState.ua;
          return FlClashHttpOverrides.handleFindProxy(uri);
        };
        client.connectionTimeout = connectTimeout;
        return client;
      },
    );

    final internalCancelToken = cancelToken ?? CancelToken();
    final stopwatch = Stopwatch()..start();
    int totalBytes = 0;
    commonPrint.log(
      'speed_test: connecting to $url'
      ' (connectTimeout=${connectTimeout.inSeconds}s'
      ', totalTimeout=${totalTimeout?.inSeconds}s)',
    );

    Future<double> doDownload() async {
      try {
        final response = await dio.get<ResponseBody>(
          url,
          cancelToken: internalCancelToken,
          options: Options(responseType: ResponseType.stream),
        );

        final statusCode = response.statusCode ?? 0;
        if (statusCode == 204) {
          throw StateError(
            'No content (204): URL is a probe endpoint, not a download file',
          );
        }
        if (statusCode != 200 && statusCode != 206) {
          throw StateError('Unexpected status $statusCode');
        }

        final stream = response.data!.stream;
        await for (final chunk in stream) {
          totalBytes += chunk.length;
        }
        commonPrint.log(
          'speed_test done: url=$url'
          ' total=${(totalBytes / 1024).toStringAsFixed(0)}KB'
          ' elapsed=${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
        );

        stopwatch.stop();
        final elapsed = stopwatch.elapsedMilliseconds / 1000.0;

        if (elapsed <= 0 || totalBytes == 0) {
          throw StateError('No data received');
        }

        final mbps = (totalBytes * 8) / (elapsed * 1000000);
        return double.parse(mbps.toStringAsFixed(1));
      } finally {
        dio.close(force: true);
      }
    }

    if (totalTimeout == null) return doDownload();

    return doDownload().timeout(
      totalTimeout,
      onTimeout: () {
        internalCancelToken.cancel('Bandwidth test total timeout');
        throw TimeoutException(
          'Bandwidth test total timeout '
          '(${totalTimeout.inSeconds}s)',
        );
      },
    );
  }

  /// Lightweight probe: sends a HEAD request through the proxy to check
  /// whether [url] is reachable. Returns `true` if any HTTP response is
  /// received (regardless of status code); returns `false` on connection
  /// error or timeout.
  static Future<bool> probeUrl(
    String url, {
    Duration connectTimeout = const Duration(seconds: defaultBandwidthConnectTimeout),
    CancelToken? cancelToken,
  }) async {
    final dio = Dio();
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (Uri uri) {
          client.userAgent = globalState.ua;
          return FlClashHttpOverrides.handleFindProxy(uri);
        };
        client.connectionTimeout = connectTimeout;
        return client;
      },
    );

    try {
      final response = await dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          method: 'HEAD',
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=0-0'},
          validateStatus: (_) => true, // accept any status
        ),
      );
      final code = response.statusCode ?? 0;
      commonPrint.log('probe_url: $url => $code');
      return code >= 100 && code < 500;
    } catch (e) {
      commonPrint.log('probe_url: $url failed: $e');
      return false;
    } finally {
      dio.close(force: true);
    }
  }
}

final speedTest = SpeedTest();