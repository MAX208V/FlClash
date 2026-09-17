import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/speed_test.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

CancelToken? _currentBandwidthCancelToken;

void cancelCurrentBandwidthTest() {
  _currentBandwidthCancelToken?.cancel('New test started');
  _currentBandwidthCancelToken = null;
}

void setCurrentBandwidthCancelToken(CancelToken token) {
  _currentBandwidthCancelToken = token;
}

double get listHeaderHeight {
  final measure = globalState.measure;
  return 20 + measure.titleMediumHeight + 4 + measure.bodyMediumHeight + 2;
}

double getItemHeight(ProxyCardType proxyCardType) {
  final measure = globalState.measure;
  final baseHeight =
      16 + measure.bodyMediumHeight * 2 + measure.bodySmallHeight + 8 + 4;
  final rowHeight = measure.bodySmallHeight > measure.labelSmallHeight * 2
      ? measure.bodySmallHeight
      : measure.labelSmallHeight * 2;
  return switch (proxyCardType) {
    ProxyCardType.expand => baseHeight + measure.labelSmallHeight * 2 + 8,
    ProxyCardType.shrink => 16 + measure.bodyMediumHeight * 2 + 8 + rowHeight + 4,
    ProxyCardType.min => baseHeight - measure.bodyMediumHeight,
  };
}

List<Group> getCurrentGroups() {
  return globalState.container.read(currentGroupsStateProvider).value;
}

List<Group> getGroups() {
  return globalState.container.read(groupsProvider);
}

void updateCurrentGroupName(String groupName) {
  globalState.container
      .read(proxiesActionProvider.notifier)
      .updateCurrentGroupName(groupName);
}

void updateCurrentUnfoldSet(Set<String> value) {
  globalState.container
      .read(proxiesActionProvider.notifier)
      .updateCurrentUnfoldSet(value);
}

Future<void> proxyDelayTest(Proxy proxy, [String? testUrl]) async {
  final ref = globalState.container;
  final groups = getGroups();
  final selectedMap = ref.read(
    currentProfileProvider.select((state) => state?.selectedMap ?? {}),
  );
  final state = computeRealSelectedProxyState(
    proxy.name,
    groups: groups,
    selectedMap: selectedMap,
  );
  final currentTestUrl = state.testUrl.takeFirstValid([
    ref.read(realTestUrlProvider(testUrl)),
  ]);
  if (state.proxyName.isEmpty) {
    return;
  }
  ref
      .read(proxiesActionProvider.notifier)
      .setDelay(Delay(url: currentTestUrl, name: state.proxyName, value: 0));
  try {
    final delay = await coreController.getDelay(
      currentTestUrl,
      state.proxyName,
    );
    ref.read(proxiesActionProvider.notifier).setDelay(delay);
  } catch (error) {
    commonPrint.log(
      'Delay test failed for ${state.proxyName}: $error',
      logLevel: coreFailureLogLevel(error),
    );
    ref
        .read(proxiesActionProvider.notifier)
        .setDelay(Delay(url: currentTestUrl, name: state.proxyName, value: -1));
  }
}

Future<void> delayTest(List<Proxy> proxies, [String? testUrl]) async {
  final batches = proxies.batch(maxConcurrentDelayTests);
  for (final batch in batches) {
    await Future.wait(
      batch.map((proxy) async {
        await proxyDelayTest(proxy, testUrl);
      }),
    );
  }
  globalState.container.read(sortNumProvider.notifier).add();
}

/// 并行探测所有测速 URL，返回有响应的有效 URL 列表。
/// 全部不可达时返回空列表，由调用方决定（所有节点直接判超时）。
Future<List<String>> probeSpeedUrls(List<String> urls) async {
  if (urls.isEmpty) return urls;

  final connectTimeout = Duration(
    seconds:
        globalState.container.read(appSettingProvider).bandwidthConnectTimeout,
  );
  commonPrint.log(
    'probeSpeedUrls: probing ${urls.length} URLs '
    '(connectTimeout=${connectTimeout.inSeconds}s)',
  );

  final results = await Future.wait(
    urls.map((url) async {
      final ok = await SpeedTest.probeUrl(
        url,
        connectTimeout: connectTimeout,
      );
      return MapEntry(url, ok);
    }),
  );

  final active = results
      .where((e) => e.value)
      .map((e) => e.key)
      .toList();

  commonPrint.log(
    'probeSpeedUrls: ${active.length}/${urls.length} URLs active'
    '${active.isEmpty ? ' (all unreachable)' : ''}',
  );
  return active;
}

Future<void> proxyBandwidthTest(
  Proxy proxy, [
  List<String>? activeUrls,
  CancelToken? cancelToken,
]) async {
  final ref = globalState.container;
  final groups = getGroups();
  final selectedMap = ref.read(
    currentProfileProvider.select((state) => state?.selectedMap ?? {}),
  );
  final state = computeRealSelectedProxyState(
    proxy.name,
    groups: groups,
    selectedMap: selectedMap,
  );
  // Always use the global speedTestUrl for bandwidth downloads.
  // Groups' testUrl (e.g. generate_204) is for delay probes, not downloads.
  final rawTestUrl = ref.read(appSettingProvider).speedTestUrl;
  if (state.proxyName.isEmpty) {
    return;
  }
  ref.read(proxiesActionProvider.notifier).setBandwidth(
    Bandwidth(name: state.proxyName, url: rawTestUrl, value: 0),
  );

  // 批量入口已全局探测过并传入 activeUrls；单节点入口在这里自己探测一次。
  final speedUrls = activeUrls ??
      await probeSpeedUrls(
        rawTestUrl
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(),
      );

  final connectTimeout = Duration(
    seconds: ref.read(appSettingProvider).bandwidthConnectTimeout,
  );
  final totalTimeout = Duration(
    seconds: ref.read(appSettingProvider).bandwidthTimeout,
  );
  commonPrint.log(
    'Bandwidth test start: ${state.proxyName} urls=$speedUrls '
    'connectTimeout=${connectTimeout.inSeconds}s '
    'totalTimeout=${totalTimeout.inSeconds}s',
  );

  // 探测后没有任何有效链接：该节点直接判超时。
  if (speedUrls.isEmpty) {
    ref.read(proxiesActionProvider.notifier).setBandwidth(
      Bandwidth(name: state.proxyName, url: rawTestUrl, value: -1),
    );
    return;
  }

  for (var i = 0; i < speedUrls.length; i++) {
    if (cancelToken?.isCancelled == true) return;
    final url = speedUrls[i];
    try {
      final mbps = await speedTest.testDownload(
        url,
        connectTimeout: connectTimeout,
        totalTimeout: totalTimeout,
        cancelToken: cancelToken,
      );
      if (mbps > 0) {
        commonPrint.log(
          'Bandwidth test OK: ${state.proxyName} ${mbps}Mbps',
        );
        ref.read(proxiesActionProvider.notifier).setBandwidth(
          Bandwidth(name: state.proxyName, url: rawTestUrl, value: mbps),
        );
        return;
      }
    } on TimeoutException catch (error) {
      // 单节点总时间超时：直接判超时，不再尝试下一个 URL。
      commonPrint.log(
        'Bandwidth test timeout for ${state.proxyName} (url: $url)',
        logLevel: coreFailureLogLevel(error),
      );
      ref.read(proxiesActionProvider.notifier).setBandwidth(
        Bandwidth(name: state.proxyName, url: rawTestUrl, value: -1),
      );
      return;
    } on DioException catch (e) {
      // CancelToken cancellation – abort immediately, do not try next URL.
      if (e.type == DioExceptionType.cancel) return;
      commonPrint.log(
        'Bandwidth test failed for ${state.proxyName} (url: $url): '
        'type=${e.type} statusCode=${e.response?.statusCode} '
        'message=${e.message} error=${e.error}',
        logLevel: coreFailureLogLevel(e),
      );
    } catch (error) {
      commonPrint.log(
        'Bandwidth test failed for ${state.proxyName} (url: $url): '
        '${error.runtimeType}: $error',
        logLevel: coreFailureLogLevel(error),
      );
    }
  }

  // All URLs failed
  ref.read(proxiesActionProvider.notifier).setBandwidth(
    Bandwidth(name: state.proxyName, url: rawTestUrl, value: -1),
  );
}

Future<void> bandwidthTest(
  List<Proxy> proxies, [
  CancelToken? cancelToken,
]) async {
  final ref = globalState.container;
  final concurrent = ref.read(appSettingProvider).bandwidthConcurrent;

  // 全局探测一次所有测速 URL，过滤死链后所有节点共享有效列表。
  final rawUrls = ref
      .read(appSettingProvider)
      .speedTestUrl
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final activeUrls = await probeSpeedUrls(rawUrls);

  if (activeUrls.isEmpty) {
    // 所有测速链接均无响应：所有节点直接判超时，不再逐个下载。
    commonPrint.log(
      'bandwidthTest: all speed URLs unreachable, '
      'marking ${proxies.length} proxies as timeout',
    );
    for (final proxy in proxies) {
      if (cancelToken?.isCancelled == true) return;
      final state = computeRealSelectedProxyState(
        proxy.name,
        groups: getGroups(),
        selectedMap: ref.read(
          currentProfileProvider.select((state) => state?.selectedMap ?? {}),
        ),
      );
      if (state.proxyName.isEmpty) continue;
      ref.read(proxiesActionProvider.notifier).setBandwidth(
        Bandwidth(
          name: state.proxyName,
          url: ref.read(appSettingProvider).speedTestUrl,
          value: -1,
        ),
      );
    }
    return;
  }

  final batches = proxies.batch(concurrent);
  for (final batch in batches) {
    if (cancelToken?.isCancelled == true) return;
    // Fire all proxies in this batch concurrently.
    final futures = batch.map(
      (proxy) => proxyBandwidthTest(proxy, activeUrls, cancelToken),
    );
    // When cancelled, don't block waiting for in-flight requests to finish.
    if (cancelToken?.isCancelled == true) return;
    await Future.wait(futures);
  }
}

double getScrollToSelectedOffset({
  required String groupName,
  required List<Proxy> proxies,
  required int columns,
}) {
  final ref = globalState.container;
  final proxyCardType = ref.read(
    proxiesStyleSettingProvider.select((state) => state.cardType),
  );
  final selectedProxyName = ref.read(selectedProxyNameProvider(groupName));
  final findSelectedIndex = proxies.indexWhere(
    (proxy) => proxy.name == selectedProxyName,
  );
  final selectedIndex = findSelectedIndex != -1 ? findSelectedIndex : 0;
  final rows = (selectedIndex / columns).floor();
  return rows * getItemHeight(proxyCardType) + (rows - 1) * 8;
}
