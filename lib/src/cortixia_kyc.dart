import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import 'backend/sdk_backend_client.dart';
import 'flows/kyc_flow_host.dart';
import 'models/kyc_models.dart';

class CortixiaKycConfig {
  /// API token issued by the Cortixia developer portal
  /// (https://www.e-kyc.online/portal/), format `ck_live_...`.
  final String apiToken;

  /// Cortixia licensing, decoding and metering server. HTTPS by default;
  /// override only for on-premise or staging deployments.
  final String baseUrl;

  /// When true, diagnostic affordances are enabled (raw datagroup export,
  /// NFC applet probe reports, verbose logs that may contain PII).
  /// Keep false in production.
  final bool debugMode;

  const CortixiaKycConfig({
    required this.apiToken,
    this.baseUrl = 'https://www.e-kyc.online',
    this.debugMode = false,
  });
}

/// Entry point of the Cortixia KYC SDK.
///
/// ```dart
/// await CortixiaKyc.initialize(CortixiaKycConfig(apiToken: 'ck_live_...'));
/// final result = await CortixiaKyc.scanIdCard(context);
/// ```
class CortixiaKyc {
  CortixiaKyc._();

  static CortixiaKycConfig? _config;
  static SdkBackendClient? _backend;
  static KycLicenseInfo? _license;
  static bool _validated = false;

  static bool get isInitialized => _config != null;

  /// The license state from the last successful online validation, if any.
  static KycLicenseInfo? get license => _license;

  /// Internal accessor for the flow layer.
  static SdkBackendClient get backend {
    final b = _backend;
    if (b == null) throw const KycNotInitializedException();
    return b;
  }

  /// Configures the SDK and validates the token against the licensing server.
  ///
  /// Throws [KycLicenseException] with [KycLicenseError.invalidToken],
  /// [KycLicenseError.licenseExpired] or [KycLicenseError.quotaExceeded] when
  /// the server rejects the token. If the server is UNREACHABLE, the SDK
  /// initializes in grace mode and revalidates on the next scan.
  static Future<KycLicenseInfo?> initialize(CortixiaKycConfig config) async {
    _config = config;
    _backend = SdkBackendClient(baseUrl: config.baseUrl, apiToken: config.apiToken);
    _license = null;
    _validated = false;
    try {
      _license = await _backend!.init();
      _validated = true;
      Logger('cortixia_kyc_sdk').info(
          'License validated: ${_license!.client} (${_license!.planCode})');
      return _license;
    } on KycLicenseException catch (e) {
      if (e.code == KycLicenseError.networkUnreachable) {
        // Offline grace: allow scanning; revalidate lazily on next scan.
        Logger('cortixia_kyc_sdk')
            .warning('License validation unreachable, grace mode: ${e.message}');
        return null;
      }
      _config = null;
      _backend = null;
      rethrow;
    }
  }

  static Future<KycResult> scanIdCard(BuildContext context,
          {KycScanOptions options = const KycScanOptions()}) =>
      _scan(context, KycDocumentType.idCard, options);

  static Future<KycResult> scanPassport(BuildContext context,
          {KycScanOptions options = const KycScanOptions()}) =>
      _scan(context, KycDocumentType.passport, options);

  static Future<KycResult> scanDrivingLicence(BuildContext context,
          {KycScanOptions options = const KycScanOptions()}) =>
      _scan(context, KycDocumentType.drivingLicence, options);

  static Future<KycResult> _scan(
    BuildContext context,
    KycDocumentType type,
    KycScanOptions options,
  ) async {
    final config = _config;
    final backend = _backend;
    if (config == null || backend == null) {
      throw const KycNotInitializedException();
    }

    // Lazy revalidation after an offline-grace init. Still unreachable →
    // keep the grace and let the scan proceed (liveness will fail loudly
    // if the server is really down).
    if (!_validated) {
      try {
        _license = await backend.init();
        _validated = true;
      } on KycLicenseException catch (e) {
        if (e.code != KycLicenseError.networkUnreachable) rethrow;
      }
    }
    final remaining = _license?.scansRemaining;
    if (_validated && remaining != null && remaining <= 0) {
      throw KycLicenseException(KycLicenseError.quotaExceeded,
          'Quota épuisé. Passez à un plan supérieur sur votre espace client.');
    }

    if (!context.mounted) return KycResult.cancelled(type);
    final result = await Navigator.of(context, rootNavigator: true).push<KycResult>(
      MaterialPageRoute(
        builder: (_) => KycFlowHost(
          documentType: type,
          options: options,
          config: config,
        ),
      ),
    );
    return result ?? KycResult.cancelled(type);
  }
}
