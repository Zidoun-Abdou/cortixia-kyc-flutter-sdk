import 'dart:typed_data';

/// Supported Algerian identity documents.
enum KycDocumentType { idCard, passport, drivingLicence }

extension KycDocumentTypeWire on KycDocumentType {
  /// Wire/legacy string used by the backend and older APIs.
  String get wire => switch (this) {
        KycDocumentType.idCard => 'idcard',
        KycDocumentType.passport => 'passport',
        KycDocumentType.drivingLicence => 'drivinglicence',
      };
}

enum KycStatus { success, cancelled, failed }

/// Decision returned by the host app's [KycScanOptions.onDocumentRead] hook,
/// called after the NFC chip is decoded and before liveness.
enum KycFlowDecision {
  /// Proceed to the face-matching/liveness step (default).
  continueToLiveness,

  /// Finish the flow successfully without liveness (e.g. the host determined
  /// this user is already verified server-side).
  completeWithoutLiveness,

  /// Abort the flow (e.g. the document belongs to a different person than a
  /// previously verified one). The scan returns [KycStatus.cancelled].
  abort,
}

typedef OnDocumentRead = Future<KycFlowDecision> Function(KycDocumentData data);

class KycScanOptions {
  /// Run the face-matching/liveness step after the chip read (default true).
  final bool withLiveness;

  /// Include the raw datagroup bytes in [KycDocumentData.rawDataGroups].
  final bool includeRawDataGroups;

  /// Host hook called after decode, before liveness. Null → always continue.
  final OnDocumentRead? onDocumentRead;

  const KycScanOptions({
    this.withLiveness = true,
    this.includeRawDataGroups = false,
    this.onDocumentRead,
  });
}

/// Identity data decoded from the document chip.
class KycDocumentData {
  final KycDocumentType documentType;

  /// firstName / firstNameAr / lastName / lastNameAr / birthDate / birthPlace /
  /// birthPlaceAr / sex / bloodType / nin (subset depends on document type).
  final Map<String, dynamic> personal;

  /// idNumber|passportNumber|licenceNumber, daira/commune(+Ar), baladia(+Ar),
  /// issueDate/creationDate, expiryDate, categories (DL only).
  final Map<String, dynamic> document;

  /// faceImage / signature as base64 JPEG strings.
  final Map<String, String> biometric;

  /// The decoder's raw per-datagroup output (dg1/dg2/dg5/dg7/dg11/dg12/dg13
  /// depending on document type). Always present; useful for hosts that need
  /// fields not covered by the mapped views.
  final Map<String, dynamic> rawDecoded;

  /// Raw datagroup bytes, only when requested via
  /// [KycScanOptions.includeRawDataGroups].
  final Map<String, Uint8List>? rawDataGroups;

  /// MRZ-derived inputs used for the BAC session.
  final String mrzDocumentNumber;
  final String mrzBirthDate;
  final String mrzExpiryDate;

  const KycDocumentData({
    required this.documentType,
    required this.personal,
    required this.document,
    required this.biometric,
    required this.rawDecoded,
    this.rawDataGroups,
    this.mrzDocumentNumber = '',
    this.mrzBirthDate = '',
    this.mrzExpiryDate = '',
  });

  Map<String, dynamic> toJson() => {
        'documentType': documentType.wire,
        'personal': personal,
        'document': document,
        'biometric': biometric,
        'mrz': {
          'documentNumber': mrzDocumentNumber,
          'birthDate': mrzBirthDate,
          'expiryDate': mrzExpiryDate,
        },
      };
}

class LivenessResult {
  /// decision == 'True' upstream.
  final bool isMatch;

  /// spoof_ratio > 0 upstream.
  final bool isSpoof;
  final double spoofRatio;

  /// Full upstream response.
  final Map<String, dynamic> raw;

  const LivenessResult({
    required this.isMatch,
    required this.isSpoof,
    required this.spoofRatio,
    required this.raw,
  });

  bool get passed => isMatch && !isSpoof;
}

class KycResult {
  final KycDocumentType documentType;
  final KycStatus status;

  /// Non-null when the chip was successfully read and decoded.
  final KycDocumentData? document;

  /// Non-null when the liveness step ran.
  final LivenessResult? liveness;

  /// Non-null when [status] == [KycStatus.failed].
  final KycException? error;

  const KycResult({
    required this.documentType,
    required this.status,
    this.document,
    this.liveness,
    this.error,
  });

  const KycResult.cancelled(this.documentType)
      : status = KycStatus.cancelled,
        document = null,
        liveness = null,
        error = null;
}

// ---------------------------------------------------------------------------
// Exceptions
// ---------------------------------------------------------------------------

sealed class KycException implements Exception {
  final String message;
  const KycException(this.message);
  @override
  String toString() => '$runtimeType: $message';
}

class KycNotInitializedException extends KycException {
  const KycNotInitializedException()
      : super('Call CortixiaKyc.initialize() before starting a scan.');
}

enum KycLicenseError { invalidToken, licenseExpired, quotaExceeded, networkUnreachable }

class KycLicenseException extends KycException {
  final KycLicenseError code;
  const KycLicenseException(this.code, super.message);
}

enum KycNfcError { nfcDisabled, tagLost, accessDenied, unsupportedDocument, readError }

class KycNfcException extends KycException {
  final KycNfcError code;
  const KycNfcException(this.code, super.message);
}

class KycCameraException extends KycException {
  const KycCameraException(super.message);
}

/// The chip was read but the server could not decode it (or was unreachable).
class KycDecodeException extends KycException {
  const KycDecodeException(super.message);
}

enum KycLivenessError { noMatch, spoofDetected, serverError, networkError }

class KycLivenessException extends KycException {
  final KycLivenessError code;
  const KycLivenessException(this.code, super.message);
}
