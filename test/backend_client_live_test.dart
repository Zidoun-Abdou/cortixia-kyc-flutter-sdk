@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cortixia_kyc_sdk/cortixia_kyc_sdk.dart';
import 'package:cortixia_kyc_sdk/src/backend/sdk_backend_client.dart';

/// Integration tests against a live Cortixia licensing server.
///
/// Supply your own credentials — no token is committed to this repository:
///
///   CORTIXIA_API_TOKEN=ck_live_xxx flutter test --tags live
///
/// Optional: CORTIXIA_BASE_URL (defaults to the production endpoint).
void main() {
  final baseUrl =
      Platform.environment['CORTIXIA_BASE_URL'] ?? 'http://167.86.104.32:8001';
  final token = Platform.environment['CORTIXIA_API_TOKEN'];

  setUpAll(() {
    if (token == null || token.isEmpty) {
      throw StateError(
          'Set CORTIXIA_API_TOKEN to run the live integration tests.');
    }
  });

  test('init succeeds with a valid token', () async {
    final client = SdkBackendClient(baseUrl: baseUrl, apiToken: token!);
    final license = await client.init();
    expect(license.client, isNotEmpty);
    expect(license.planCode, isNotEmpty);
    expect(license.features['doc_types'], isA<List<dynamic>>());
  });

  test('init throws invalidToken for a bad key', () async {
    final client = SdkBackendClient(baseUrl: baseUrl, apiToken: 'ck_live_WRONG');
    expect(
      () => client.init(),
      throwsA(isA<KycLicenseException>()
          .having((e) => e.code, 'code', KycLicenseError.invalidToken)),
    );
  });

  test('usage events are accepted', () async {
    final client = SdkBackendClient(baseUrl: baseUrl, apiToken: token!);
    final sessionId = SdkBackendClient.newSessionId();
    final started = await client.postEvent(
      eventType: 'scan_started',
      documentType: 'idcard',
      sessionId: sessionId,
    );
    expect(started, isTrue);
  });

  test('postEvent never throws on a bad token', () async {
    final client = SdkBackendClient(baseUrl: baseUrl, apiToken: 'ck_live_WRONG');
    final ok = await client.postEvent(
      eventType: 'scan_started',
      documentType: 'idcard',
      sessionId: SdkBackendClient.newSessionId(),
    );
    expect(ok, isFalse);
  });
}
