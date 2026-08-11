import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../models/kyc_models.dart';

/// License/quota state returned by the licensing server at init.
class KycLicenseInfo {
  final String client;
  final String planCode;
  final String planName;
  final int? scansRemaining; // null when the plan is unlimited
  final bool unlimited;
  final DateTime? periodEnd;
  final Map<String, dynamic> features;

  /// Capability packs active on the account: 'mrz', 'nfc', 'liveness'.
  final Set<String> packs;

  /// Per-pack display info keyed by pack code.
  final Map<String, dynamic> packInfo;

  const KycLicenseInfo({
    required this.client,
    required this.planCode,
    required this.planName,
    required this.scansRemaining,
    required this.unlimited,
    required this.periodEnd,
    required this.features,
    this.packs = const {},
    this.packInfo = const {},
  });

  factory KycLicenseInfo.fromJson(Map<String, dynamic> json) {
    final plan = (json['plan'] as Map<String, dynamic>?) ?? const {};
    final quota = (json['quota'] as Map<String, dynamic>?) ?? const {};
    return KycLicenseInfo(
      client: json['client'] as String? ?? '',
      planCode: plan['code'] as String? ?? '',
      planName: plan['name'] as String? ?? '',
      scansRemaining: quota['remaining'] as int?,
      unlimited: quota['unlimited'] as bool? ?? false,
      periodEnd: DateTime.tryParse(quota['period_end'] as String? ?? ''),
      features: (json['features'] as Map<String, dynamic>?) ?? const {},
      packs: _readPacks(json),
      packInfo: ((json['entitlements'] as Map<String, dynamic>?)?['pack_info']
              as Map<String, dynamic>?) ??
          const {},
    );
  }

  /// Prefers the entitlements block, falling back to `features.packs` so an
  /// older server response still yields something usable.
  static Set<String> _readPacks(Map<String, dynamic> json) {
    final entitlements = json['entitlements'] as Map<String, dynamic>?;
    final raw = (entitlements?['packs'] ?? (json['features'] as Map?)?['packs']);
    if (raw is List) return raw.map((e) => '$e').toSet();
    return const {};
  }
}

/// HTTP client for the Cortixia licensing/metering API (/api/sdk/v1/).
class SdkBackendClient {
  static const sdkVersion = '0.3.4';

  final String baseUrl;
  final String apiToken;
  final _log = Logger('cortixia_kyc_sdk.backend');

  SdkBackendClient({required this.baseUrl, required this.apiToken});

  Map<String, String> get _headers => {
        'X-API-Key': apiToken,
        'Content-Type': 'application/json',
      };

  /// Validates the token and returns the license state.
  /// Throws [KycLicenseException] on 401/402 or network failure.
  Future<KycLicenseInfo> init({String platform = 'android'}) async {
    final http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse('$baseUrl/api/sdk/v1/init'),
            headers: _headers,
            body: jsonEncode({'sdk_version': sdkVersion, 'platform': platform}),
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw KycLicenseException(
          KycLicenseError.networkUnreachable, 'Licensing server unreachable: $e');
    }
    if (resp.statusCode == 200) {
      return KycLicenseInfo.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
    }
    throw _licenseErrorFrom(resp);
  }

  /// Validates and parses MRZ lines read by the camera.
  ///
  /// Called once per candidate — never per camera frame; see MrzPrefilter.
  /// Throws [KycLicenseException] on 401/402 and [KycMrzException] when the
  /// server rejects the lines (bad check digits), which is NOT billed.
  Future<Map<String, dynamic>> parseMrz({
    required String documentType,
    required List<String> lines,
    String sessionId = '',
    String platform = 'android',
  }) async {
    final body = jsonEncode({
      'document_type': documentType,
      'lines': lines,
      'session_id': sessionId,
      'sdk_version': sdkVersion,
      'platform': platform,
    });

    final http.Response resp;
    try {
      resp = await http
          .post(Uri.parse('$baseUrl/api/sdk/v1/mrz'), headers: _headers, body: body)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw KycMrzException('Service de lecture MRZ injoignable: $e');
    }

    if (resp.statusCode == 200) {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    }
    if (resp.statusCode == 401 || resp.statusCode == 402) {
      throw _licenseErrorFrom(resp);
    }
    // A raw status code tells the person holding the phone nothing about what
    // to do next. Prefer the server's message; fall back to an instruction.
    String message =
        'MRZ illisible. Repositionnez le document bien à plat et réessayez.';
    try {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      if (json['message'] is String) message = json['message'] as String;
    } catch (_) {}
    throw KycMrzException(message);
  }

  /// Decodes raw datagroup bytes read from the document chip.
  ///
  /// Decoding runs on the Cortixia server: this is the SDK's billable
  /// operation and the reason a valid token is required to obtain identity
  /// data. Returns the decoded map (one entry per datagroup).
  ///
  /// Throws [KycLicenseException] on 401/402 and [KycDecodeException] when the
  /// server could not decode the supplied bytes.
  Future<Map<String, dynamic>> decode({
    required String documentType,
    required Map<String, Uint8List> datagroups,
    String sessionId = '',
    String platform = 'android',
  }) async {
    final body = jsonEncode({
      'document_type': documentType,
      'session_id': sessionId,
      'sdk_version': sdkVersion,
      'platform': platform,
      'datagroups': {
        for (final entry in datagroups.entries)
          if (entry.value.isNotEmpty) entry.key: base64Encode(entry.value),
      },
    });

    final http.Response resp;
    try {
      resp = await http
          .post(Uri.parse('$baseUrl/api/sdk/v1/decode'),
              headers: _headers, body: body)
          .timeout(const Duration(seconds: 60));
    } catch (e) {
      throw KycDecodeException('Decode server unreachable: $e');
    }

    if (resp.statusCode == 200) {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return (json['decoded'] as Map<String, dynamic>?) ?? const {};
    }
    if (resp.statusCode == 401 || resp.statusCode == 402) {
      throw _licenseErrorFrom(resp);
    }
    String message = 'Decode failed: HTTP ${resp.statusCode}';
    try {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      if (json['message'] is String) message = json['message'] as String;
    } catch (_) {}
    throw KycDecodeException(message);
  }

  /// Best-effort usage event (scan_started / scan_completed). Never throws;
  /// returns false when the server rejected the event for quota reasons.
  Future<bool> postEvent({
    required String eventType,
    required String documentType,
    required String sessionId,
    bool success = true,
    String errorCode = '',
    String platform = 'android',
  }) async {
    final body = jsonEncode({
      'session_id': sessionId,
      'event_type': eventType,
      'document_type': documentType,
      'success': success,
      'error_code': errorCode,
      'sdk_version': sdkVersion,
      'platform': platform,
    });
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final resp = await http
            .post(Uri.parse('$baseUrl/api/sdk/v1/events'),
                headers: _headers, body: body)
            .timeout(const Duration(seconds: 10));
        if (resp.statusCode == 201) return true;
        if (resp.statusCode == 402) {
          _log.warning('Usage event rejected: quota exceeded');
          return false;
        }
        _log.warning('Usage event failed: HTTP ${resp.statusCode}');
        return false;
      } catch (e) {
        if (attempt == 1) _log.warning('Usage event failed: $e');
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    return false;
  }

  /// Metered liveness check through the portal proxy. Returns the upstream
  /// response body (decision/details/quota). Throws [KycLicenseException] on
  /// 401/402 and [KycLivenessException] on server/network errors.
  Future<Map<String, dynamic>> liveness({
    required Uint8List faceBytes,
    required String videoPath,
    String question = 'neutral',
    String sessionId = '',
    String platform = 'android',
  }) async {
    final request = http.MultipartRequest(
        'POST', Uri.parse('$baseUrl/api/sdk/v1/liveness'))
      ..headers['X-API-Key'] = apiToken
      ..fields['question'] = question
      ..fields['session_id'] = sessionId
      ..fields['sdk_version'] = sdkVersion
      ..fields['platform'] = platform;
    try {
      request.files.add(http.MultipartFile.fromBytes('face', faceBytes,
          filename: 'face.jpg'));
      request.files.add(await http.MultipartFile.fromPath('video', videoPath));
      final streamed = await request.send().timeout(const Duration(seconds: 90));
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
      if (resp.statusCode == 401 || resp.statusCode == 402) {
        throw _licenseErrorFrom(resp);
      }
      // Never surface a raw status code to an end user. The liveness upstream
      // can be momentarily unavailable (502); the portal returns a French
      // message for exactly that case — prefer it, and fall back to a
      // retryable instruction rather than "HTTP 502".
      String message =
          "Service de vérification momentanément indisponible. Réessayez.";
      try {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final m = body['message'];
        if (m is String && m.isNotEmpty) message = m;
      } catch (_) {}
      throw KycLivenessException(KycLivenessError.serverError, message);
    } on KycException {
      rethrow;
    } catch (e) {
      throw KycLivenessException(
          KycLivenessError.networkError, 'Liveness request failed: $e');
    }
  }

  KycLicenseException _licenseErrorFrom(http.Response resp) {
    String error = '';
    String message = '';
    try {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      error = body['error'] as String? ?? '';
      message = body['message'] as String? ?? '';
    } catch (_) {}
    return switch (error) {
      'quota_exceeded' => KycLicenseException(KycLicenseError.quotaExceeded,
          message.isNotEmpty ? message : 'Quota épuisé.'),
      'no_active_subscription' => KycLicenseException(
          KycLicenseError.licenseExpired,
          message.isNotEmpty ? message : 'Aucun abonnement actif.'),
      'pack_not_entitled' => KycLicenseException(KycLicenseError.packNotEntitled,
          message.isNotEmpty ? message : "Pack non activé sur votre compte."),
      _ => KycLicenseException(KycLicenseError.invalidToken,
          message.isNotEmpty ? message : 'Jeton API invalide.'),
    };
  }

  /// Random per-flow session id (no uuid dependency).
  static String newSessionId() {
    final rand = Random();
    final now = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    final salt =
        List.generate(4, (_) => rand.nextInt(65536).toRadixString(16).padLeft(4, '0'))
            .join();
    return 's$now$salt';
  }
}
