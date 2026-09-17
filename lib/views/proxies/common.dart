import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/constant.dart';
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

/// Probe all configured speed-test URLs in parallel and return only
/// the ones that are reachable (i.e. returned any HTTP response).
/// If all URLs fail, returns the original list as fallback so that
/// per-proxy tests still have URLs to try.
Future<List<String>> probeSpeedUrls(List<String> urls) async {
  if (urls.length <= 1) return urls;

  final connectTimeout = Duration(
    seconds: globalState.container.read(appSettingProvider).bandwidthConnectTimeout,
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

  if (active.isEmpty) {
    commonPrint.log('probeSpeedUrls: all URLs unreachable, using originals');
    return urls;
  }

  commonPrint.log(
    'probeSpeedUrls: ${active.length}/${urls.length} URLs active',
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
  final rawTestUrl = ref.read(appSettingProvider).speedTestUrl;
  if (state.proxyName.isEmpty) return;

  ref.read(proxiesActionProvider.notifier).setBandwidth(
    Bandwidth(name: state.proxyName, url: rawTestUrl, value: 0),
  );

  // Use probed URLs if available; otherwise split comma-separated URLs
  final speedUrls = activeUrls ??
      rawTestUrl
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();

  final connectTimeout = Duration(
    seconds: ref.read(appSettingProvider).bandwidthConnectTimeout,
  );
  final totalTimeout = Duration(
    seconds: ref.read(appSettingProvider).bandwidthTimeout,
  );
  commonPrint.log(
    'bandwidth test start: ${state.proxyName} urls=$speedUrls '
    'connectTimeout=${connectTimeout.inSeconds}s '
    'totalTimeout=${totalTimeout.inSeconds}s',
  );

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
          'bandwidth test OK: ${state.proxyName} ${mbps}Mbps',
        );
        ref.read(proxiesActionProvider.notifier).setBandwidth(
          Bandwidth(name: state.proxyName, url: rawTestUrl, value: mbps),
        );
        return;
      }
    } on TimeoutException {
      commonPrint.log(
        'bandwidth test timeout for ${state.proxyName} (url: $url)',
      );
      // Total timeout hit – don't try next URL, report -1 directly
      ref.read(proxiesActionProvider.notifier).setBandwidth(
        Bandwidth(name: state.proxyName, url: rawTestUrl, value: -1),
      );
      return;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;
      commonPrint.log(
        'bandwidth test failed for ${state.proxyName} (url: $url): '
        'type=${e.type} statusCode=${e.response?.statusCode} '
        'message=${e.message} error=${e.error}',
        logLevel: coreFailureLogLevel(e),
      );
    } catch (error) {
      commonPrint.log(
        'bandwidth test failed for ${state.proxyName} (url: $url): '
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

  // Probe all speed-test URLs upfront before per-proxy testing
  final rawUrls = ref
      .read(appSettingProvider)
      .speedTestUrl
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final activeUrls = await probeSpeedUrls(rawUrls);

  final batches = proxies.batch(concurrent);
  for (final batch in batches) {
    if (cancelToken?.isCancelled == true) return;
    final futures = batch.map(
      (proxy) => proxyBandwidthTest(proxy, activeUrls, cancelToken),
    );
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
