import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/state.dart';

/// Downloads a file through the Clash proxy and returns the measured speed
/// in Mbps (megabits per second).
class SpeedTest {
  Future<double> testDownload(
    String url, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final dio = Dio();
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (Uri uri) {
          client.userAgent = globalState.ua;
          return FlClashHttpOverrides.handleFindProxy(uri);
        };
        client.connectionTimeout = timeout;
        return client;
      },
    );

    final cancelToken = CancelToken();
    final stopwatch = Stopwatch()..start();
    int totalBytes = 0;

    try {
      final response = await dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(responseType: ResponseType.stream),
      );

      final stream = response.data!.stream;
      await for (final chunk in stream) {
        totalBytes += chunk.length;
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
