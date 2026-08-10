import 'dart:typed_data';

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

  // -- modular entry points (one pack each) --------------------------------

  /// Reads only the document's machine-readable zone. Requires the MRZ pack.
  ///
  /// Returns null when the user backs out.
  static Future<MrzResult?> scanMrz(
    BuildContext context,
    KycDocumentType documentType, {
    MrzScanOptions options = const MrzScanOptions(),
  }) async {
    _requirePack('mrz');
    final result = await _run(context, documentType,
        const KycScanOptions(withLiveness: false), KycFlowMode.mrzOnly,
        mrzOptions: options);
    return result?.mrz;
  }

  /// Reads and decodes the chip. Requires the NFC pack.
  ///
  /// Supply either [mrz] (from [scanMrz]) or the three BAC inputs directly —
  /// useful when your system already holds them. Returns null on cancel.
  static Future<KycDocumentData?> readChip(
    BuildContext context,
    KycDocumentType documentType, {
    MrzResult? mrz,
    String? documentNumber,
    String? birthDate,
    String? expiryDate,
    bool includeRawDataGroups = false,
  }) async {
    _requirePack('nfc');
    final hasExplicit =
        documentNumber != null && birthDate != null && expiryDate != null;
    assert(mrz != null || hasExplicit,
        'readChip needs either `mrz` or documentNumber + birthDate + expiryDate.');
    if (mrz == null && !hasExplicit) {
      throw ArgumentError(
          'readChip needs either `mrz` or documentNumber + birthDate + expiryDate.');
    }

    final result = await _run(
      context,
      documentType,
      KycScanOptions(withLiveness: false, includeRawDataGroups: includeRawDataGroups),
      KycFlowMode.nfcOnly,
      bacKeys: BacKeys(
        documentNumber: mrz?.documentNumber ?? documentNumber!,
        birthDate: mrz?.birthDateMrz ?? birthDate!,
        expiryDate: mrz?.expiryDateMrz ?? expiryDate!,
      ),
    );
    return result?.document;
  }

  /// Runs liveness against a reference face you supply. Requires the
  /// Liveness pack. Returns null on cancel.
  static Future<LivenessResult?> checkLiveness(
    BuildContext context, {
    required Uint8List referenceFace,
  }) async {
    _requirePack('liveness');
    final result = await _run(context, KycDocumentType.idCard,
        const KycScanOptions(), KycFlowMode.livenessOnly,
        referenceFace: referenceFace);
    return result?.liveness;
  }

  /// Client-side courtesy check so a pack the account does not hold fails
  /// before the camera opens. The server remains the real gate.
  static void _requirePack(String code) {
    final licence = _license;
    if (_validated && licence != null && licence.packs.isNotEmpty &&
        !licence.packs.contains(code)) {
      throw KycLicenseException(
        KycLicenseError.packNotEntitled,
        "Pack « $code » non activé sur votre compte.",
      );
    }
  }

  static Future<KycResult?> _run(
    BuildContext context,
    KycDocumentType type,
    KycScanOptions options,
    KycFlowMode mode, {
    BacKeys? bacKeys,
    Uint8List? referenceFace,
    MrzScanOptions? mrzOptions,
  }) async {
    final config = _config;
    if (config == null || _backend == null) {
      throw const KycNotInitializedException();
    }
    await _ensureValidated();
    if (!context.mounted) return null;

    final result = await Navigator.of(context, rootNavigator: true).push<KycResult>(
      MaterialPageRoute(
        builder: (_) => KycFlowHost(
          documentType: type,
          options: options,
          config: config,
          mode: mode,
          bacKeys: bacKeys,
          referenceFace: referenceFace,
          mrzOptions: mrzOptions,
        ),
      ),
    );
    if (result == null || result.status == KycStatus.cancelled) return null;
    if (result.status == KycStatus.failed && result.error != null) {
      throw result.error!;
    }
    return result;
  }

  static Future<void> _ensureValidated() async {
    if (_validated) return;
    try {
      _license = await _backend!.init();
      _validated = true;
    } on KycLicenseException catch (e) {
      if (e.code != KycLicenseError.networkUnreachable) rethrow;
    }
  }

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
    // keep the grace and let the scan proceed (the first billable call will
    // fail loudly if the server is really down).
    await _ensureValidated();
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
