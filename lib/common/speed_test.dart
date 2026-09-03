import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/state.dart';

/// Downloads a file through the Clash proxy and returns the measured speed
/// in Mbps (megabits per second).
class SpeedTest {
  /// 测带宽：[connectTimeout] 控制连通性超时（默认 10s），
  /// 下载本身不设超时，自然跑完以准确计算速度。
  Future<double> testDownload(
    String url, {
    Duration connectTimeout = const Duration(seconds: 10),
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
    commonPrint.log('speed_test: connecting to $url (connectTimeout=${connectTimeout.inSeconds}s)');

    try {
      final response = await dio.get<ResponseBody>(
        url,
        cancelToken: internalCancelToken,
        options: Options(responseType: ResponseType.stream),
      );

      // Accept both 200 OK and 206 Partial Content (Range requests).
      final statusCode = response.statusCode ?? 0;
      if (statusCode != 200 && statusCode != 206) {
        throw StateError('Unexpected status $statusCode');
      }

      final stream = response.data!.stream;
      await for (final chunk in stream) {
        totalBytes += chunk.length;
        // Log progress every ~2MB
        if (totalBytes % (2 * 1024 * 1024) < chunk.length) {
          commonPrint.log('Bandwidth download progress: ${totalBytes ~/ 1024}KB');
        }
      }

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
}

final speedTest = SpeedTest();
