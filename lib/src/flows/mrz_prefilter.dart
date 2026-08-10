import '../models/kyc_models.dart';

/// Decides when OCR output is worth sending to the server.
///
/// The camera produces 5–10 frames per second; `/api/sdk/v1/mrz` must be
/// called **once per candidate**, never per frame. This gate is local and
/// cheap: it only decides *whether* to ask. The server remains the sole
/// authority on whether an MRZ is valid — no parsing happens here, because a
/// local parse would defeat the pack gate it is meant to protect.
class MrzPrefilter {
  MrzPrefilter(this.documentType);

  final KycDocumentType documentType;

  /// Line sets already sent this session, so a stable read is not billed twice.
  final Set<String> _submitted = <String>{};

  List<String>? _lastCandidate;
  DateTime? _lastAttempt;
  int _calls = 0;
  bool inFlight = false;

  static const maxCallsPerScan = 5;
  static const _minGap = Duration(milliseconds: 1500);

  static final _td1Line = RegExp(r'^[A-Z0-9<]{28,32}$');
  static final _td3Line = RegExp(r'^[A-Z0-9<]{42,46}$');
  static final _docNumber = RegExp(r'^[A-Z0-9]{9}$');
  static final _sixDigits = RegExp(r'^\d{6}$');

  int get lineCount => documentType == KycDocumentType.passport ? 2 : 3;
  bool get exhausted => _calls >= maxCallsPerScan;

  /// Uppercase and remove whitespace. Never "corrects" characters: billing
  /// correctness depends on an invalid MRZ staying invalid.
  static List<String> normalise(Iterable<String> lines) =>
      lines.map((l) => l.replaceAll(RegExp(r'\s+'), '').toUpperCase()).toList();

  /// Shape check only — is this plausibly an MRZ of the expected format?
  bool looksLikeMrz(List<String> lines) {
    if (lines.length != lineCount) return false;

    final pattern = documentType == KycDocumentType.passport ? _td3Line : _td1Line;
    if (!lines.every(pattern.hasMatch)) return false;

    final first = lines.first;
    final prefixOk = switch (documentType) {
      KycDocumentType.passport => first.startsWith('P'),
      KycDocumentType.drivingLicence => first.startsWith('DL'),
      KycDocumentType.idCard => first.startsWith('ID') || first.startsWith('I<'),
    };
    if (!prefixOk) return false;

    if (documentType == KycDocumentType.passport) {
      final l2 = lines[1];
      return _docNumber.hasMatch(l2.substring(0, 9)) &&
          _sixDigits.hasMatch(l2.substring(13, 19)) &&
          _sixDigits.hasMatch(l2.substring(21, 27));
    }

    final l1 = lines[0], l2 = lines[1];
    return _docNumber.hasMatch(l1.substring(5, 14)) &&
        _sixDigits.hasMatch(l2.substring(0, 6)) &&
        _sixDigits.hasMatch(l2.substring(8, 14));
  }

  /// Returns the lines to submit, or null to keep scanning.
  ///
  /// Requires the SAME normalised lines on two consecutive accepted frames,
  /// which filters out transient OCR noise before spending a request.
  List<String>? offer(Iterable<String> rawLines) {
    if (inFlight || exhausted) return null;

    final lines = normalise(rawLines);
    if (!looksLikeMrz(lines)) {
      _lastCandidate = null;
      return null;
    }

    final key = lines.join('|');
    if (_submitted.contains(key)) return null;

    if (_lastCandidate == null || _lastCandidate!.join('|') != key) {
      _lastCandidate = lines; // first sighting — wait for confirmation
      return null;
    }

    final now = DateTime.now();
    if (_lastAttempt != null && now.difference(_lastAttempt!) < _minGap) {
      return null;
    }

    _lastAttempt = now;
    _submitted.add(key);
    _calls++;
    return lines;
  }

  void reset() {
    _submitted.clear();
    _lastCandidate = null;
    _lastAttempt = null;
    _calls = 0;
    inFlight = false;
  }
}
