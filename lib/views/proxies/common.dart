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

Future<void> proxyBandwidthTest(
  Proxy proxy, [
  String? testUrl,
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
  final currentTestUrl = state.testUrl.takeFirstValid([
    ref.read(realSpeedTestUrlProvider(testUrl)),
  ]);
  if (state.proxyName.isEmpty) {
    return;
  }
  ref.read(proxiesActionProvider.notifier).setBandwidth(
    Bandwidth(name: state.proxyName, url: currentTestUrl, value: 0),
  );

  // Split comma-separated URLs for fallback
  final speedUrls = currentTestUrl
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final timeout = Duration(
    seconds: ref.read(appSettingProvider).bandwidthTimeout,
  );

  for (var i = 0; i < speedUrls.length; i++) {
    if (cancelToken?.isCancelled == true) return;
    final url = speedUrls[i];
    try {
      final mbps = await speedTest.testDownload(
        url,
        timeout: timeout,
        cancelToken: cancelToken,
      );
      if (mbps > 0) {
        ref.read(proxiesActionProvider.notifier).setBandwidth(
          Bandwidth(name: state.proxyName, url: currentTestUrl, value: mbps),
        );
        return;
      }
    } on DioException catch (e) {
      // CancelToken cancellation – abort immediately, do not try next URL.
      if (e.type == DioExceptionType.cancel) return;
      commonPrint.log(
        'Bandwidth test failed for ${state.proxyName} (url: $url): $e',
        logLevel: coreFailureLogLevel(e),
      );
    } catch (error) {
      commonPrint.log(
        'Bandwidth test failed for ${state.proxyName} (url: $url): $error',
        logLevel: coreFailureLogLevel(error),
      );
    }
  }

  // All URLs failed
  ref.read(proxiesActionProvider.notifier).setBandwidth(
    Bandwidth(name: state.proxyName, url: currentTestUrl, value: -1),
  );
}

Future<void> bandwidthTest(
  List<Proxy> proxies, [
  String? testUrl,
  CancelToken? cancelToken,
]) async {
  final ref = globalState.container;
  final concurrent = ref.read(appSettingProvider).bandwidthConcurrent;
  final batches = proxies.batch(concurrent);
  for (final batch in batches) {
    if (cancelToken?.isCancelled == true) return;
    // Fire all proxies in this batch concurrently.
    final futures = batch.map(
      (proxy) => proxyBandwidthTest(proxy, testUrl, cancelToken),
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
