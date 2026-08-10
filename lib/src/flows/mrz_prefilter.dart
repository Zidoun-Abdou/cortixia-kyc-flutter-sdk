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

  /// Single-width glyphs OCR produces for the MRZ filler `<`. None of these
  /// exist in the MRZ alphabet (`A-Z`, `0-9`, `<`), so the mapping is exact.
  static final _singleGlyph = RegExp(r'[\u2039\u203A\u3008\u3009\u2329\u232A'
      r'\uFF1C\uFF1E\u02C2\u02C3]');

  /// Double-width angle quotes. ML Kit emits one of these for a `<<` pair —
  /// but a bold or serifed single `<` can also read as `«`, so the width is
  /// genuinely ambiguous and is resolved by line length below.
  static final _doubleGlyph = RegExp(r'[\u00AB\u00BB\u226A\u226B]');

  /// Expected characters per line: TD3 (passport) is 44, TD1 and the driving
  /// licence are 30.
  int get _lineLength => documentType == KycDocumentType.passport ? 44 : 30;

  /// Uppercase, strip whitespace, and map OCR glyphs that can ONLY be a
  /// misread filler character.
  ///
  /// This is character-set normalisation, not content correction, and the
  /// distinction is what makes it safe. Guessing `O`->`0` or `S`->`5` would be
  /// a guess about the *content* and could turn an invalid MRZ into a
  /// valid-looking wrong one — so that is still never done. The glyphs handled
  /// here are not members of the MRZ alphabet at all, so nothing is invented.
  ///
  /// Width ambiguity is resolved by the fixed line length rather than assumed:
  /// whichever of `<` or `<<` lands the line on its expected size is the right
  /// reading. If neither does, the line is broken for other reasons and the
  /// server rejects it as it would have anyway — the check digits remain the
  /// final authority, so a mistaken expansion cannot manufacture a valid MRZ.
  List<String> normaliseLines(Iterable<String> lines) => lines.map((line) {
        var out = line
            .replaceAll(RegExp(r'\s+'), '')
            .toUpperCase()
            .replaceAll(_singleGlyph, '<');
        if (_doubleGlyph.hasMatch(out)) {
          final asDouble = out.replaceAll(_doubleGlyph, '<<');
          final asSingle = out.replaceAll(_doubleGlyph, '<');
          out = asDouble.length == _lineLength
              ? asDouble
              : asSingle.length == _lineLength
                  ? asSingle
                  : asDouble; // a double chevron is the commoner reading
        }
        return out;
      }).toList();

  /// Length-agnostic form, for callers without a document type in hand.
  /// Prefer [normaliseLines]: it can disambiguate the double-width glyphs.
  static List<String> normalise(Iterable<String> lines) => lines
      .map((l) => l
          .replaceAll(RegExp(r'\s+'), '')
          .toUpperCase()
          .replaceAll(_singleGlyph, '<')
          .replaceAll(_doubleGlyph, '<<'))
      .toList();

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
