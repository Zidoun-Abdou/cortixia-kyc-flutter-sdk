import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dmrtd/dmrtd.dart';
import 'package:dmrtd/extensions.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'package:camera/camera.dart';
import '../liveness/face_matching_page.dart';
import '../../models/kyc_models.dart';
import '../kyc_flow_host.dart';

class DrivingLicenceReadNfcPage extends StatefulWidget {
  final List<CameraDescription> cameras;
  final String licenceNumber;
  final String dob;
  final String doe;

  const DrivingLicenceReadNfcPage({
    super.key,
    required this.cameras,
    required this.licenceNumber,
    required this.dob,
    required this.doe,
  });

  @override
  State<DrivingLicenceReadNfcPage> createState() => _DrivingLicenceReadNfcPageState();
}

class _DrivingLicenceReadNfcPageState extends State<DrivingLicenceReadNfcPage> with SingleTickerProviderStateMixin {
  static const _accent = Color(0xFF059669);
  static const _accentDark = Color(0xFF047857);

  final _log = Logger('cortixiakyc.drivinglicence.nfc');
  final _nfc = NfcProvider();
  bool _reading = false;
  String _status = '';
  Map<String, dynamic>? _decoded;
  Uint8List? _faceBytes;
  bool _showFaceMatching = false;
  late AnimationController _animationController;
  late Animation<double> _pulseAnimation;

  /// Captured during the AID probe so the user can copy/share it.
  String? _probeReport;

  /// Captured during SFI enumeration after a successful BAC session, so
  /// the user can copy/share the file map.
  String? _sfiDump;

  /// Tracks whether the previous chunk read returned an SM-breaking SW
  /// (6882 / 6987 / 6988). When true, the next DG read calls
  /// [Passport.reinitSmSession] before issuing the first APDU.
  bool _smBroken = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(
      begin: 1.0,
      end: 1.2,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _checkNfcAndScan() async {
    final status = await NfcProvider.nfcStatus;
    if (status != NfcStatus.enabled && mounted) {
      setState(() => _status = '⚠️ NFC est désactivé. Veuillez l\'activer et réessayer.');
      return;
    }
    await _readMRTD();
  }

  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  Future<void> _readMRTD() async {
    _safeSetState(() {
      _reading = true;
      _status = '📱 Approchez le permis du téléphone…';
      _decoded = null;
      _probeReport = null;
      _sfiDump = null;
    });

    try {
      await _nfc.connect();
      final passport = Passport(_nfc);

      _safeSetState(() => _status = '🔐 Démarrage de la session sécurisée (applet IDL)…');

      final dob = DateTime.parse(widget.dob);
      final doe = DateTime.parse(widget.doe);
      final bac = DBAKeys(widget.licenceNumber, dob, doe);

      // BAC sometimes fails on the very first attempt with 6982/63CF when
      // the chip is at the edge of the NFC field or recovering from a
      // prior session. One forced re-SELECT + retry usually clears it.
      await _startDlSessionWithRetry(passport, bac);

      _safeSetState(() => _status = '📖 BAC OK. Lecture 1/6 — Données…');

      // Read the six IDL DGs we know about. Between reads we proactively
      // re-init SM if the previous read returned an SM-breaking SW
      // (6987 / 6882 / 6982). Without that, a single bad chunk in the
      // middle of one DG poisons every subsequent DG (we saw this when
      // DG5 broke SM and then DG7/DG13 came back with 6882/0 bytes).
      final dg1Bytes = await _readFullWithRecovery(passport, 0x01, 'DG1',
          stepNum: 1, stepLabel: 'Données personnelles');
      final dg11Bytes = await _readFullWithRecovery(passport, 0x02, 'DG11 (sex+place)',
          stepNum: 2, stepLabel: 'Sexe + lieu de naissance');
      final dg12Bytes = await _readFullWithRecovery(passport, 0x03, 'DG12 (NIN)',
          stepNum: 3, stepLabel: 'NIN');
      final dg5Bytes = await _readFullWithRecovery(passport, 0x04, 'DG5 (portrait)',
          stepNum: 4, stepLabel: 'Photo d\'identité',
          maxFileSize: 32768);
      final dg7Bytes = await _readFullWithRecovery(passport, 0x05, 'DG7 (signature)',
          stepNum: 5, stepLabel: 'Signature',
          maxFileSize: 16384);
      final dg13Bytes = await _readFullWithRecovery(passport, 0x0B, 'DG13 (Arabic)',
          stepNum: 6, stepLabel: 'Données en arabe');

      _safeSetState(() => _status = '🔄 Décodage des données…');

      if (!mounted) return;
      final host = KycFlowHost.of(context);
      final decoded = await host.backend.decode(
        documentType: 'drivinglicence',
        sessionId: host.sessionId,
        datagroups: {
          if (dg1Bytes != null) 'sfi01': dg1Bytes,
          if (dg11Bytes != null) 'sfi02': dg11Bytes,
          if (dg12Bytes != null) 'sfi03': dg12Bytes,
          if (dg5Bytes != null) 'sfi04': dg5Bytes,
          if (dg7Bytes != null) 'sfi05': dg7Bytes,
          if (dg13Bytes != null) 'sfi0B': dg13Bytes,
        },
      );

      _safeSetState(() {
        _decoded = decoded;
        _status = '✅ Décodé avec succès!';
      });

      await _saveFaceImage();

      if (!mounted) return;
      final decision = await host.documentRead(
        decoded,
        mrzDocumentNumber: widget.licenceNumber,
        mrzBirthDate: widget.dob,
        mrzExpiryDate: widget.doe,
      );
      switch (decision) {
        case KycFlowDecision.abort:
          host.cancel();
          return;
        case KycFlowDecision.completeWithoutLiveness:
          host.completeSuccess();
          return;
        case KycFlowDecision.continueToLiveness:
          _safeSetState(() {
            _showFaceMatching = true;
          });
      }
    } on KycException catch (e) {
      // Licence/quota problem or the decode service is unavailable. The chip
      // read fine, so do NOT run the AID diagnostic here.
      _log.warning('Décodage impossible: ${e.message}');
      if (mounted) {
        _safeSetState(() => _status = '❌ ${e.message}');
        KycFlowHost.of(context).completeFailed(e);
      }
    } catch (e, st) {
      _log.warning('Échec de la lecture: $e\n$st');
      // The chip rejected the IDL AID, BAC failed, or the read loop
      // crashed. Run the AID probe so we know which one happened.
      String report;
      try {
        report = await _probeAids();
      } catch (probeErr) {
        report = 'Diagnostic échoué: $probeErr';
      }
      _safeSetState(() {
        _status = '❌ Erreur de lecture: ${e.toString()}\n\nDiagnostic AID exécuté — voir ci-dessous.';
        _probeReport = report;
      });
    } finally {
      try {
        await _nfc.disconnect(iosAlertMessage: 'Terminé');
      } catch (_) {}
      _safeSetState(() {
        _reading = false;
      });
    }
  }

  /// Starts the DL BAC session, retrying once on transient
  /// authentication failures (SW=6982 / 63CF / 6300). On retry we
  /// force a re-SELECT of the IDL applet so the chip gets a fresh
  /// state. Most "intermittent" failures users report are the chip
  /// being half-in-field during the first MUTUAL AUTHENTICATE — the
  /// second attempt nearly always works.
  Future<void> _startDlSessionWithRetry(Passport passport, DBAKeys bac) async {
    const transient = [0x6982, 0x63CF, 0x6300];
    for (int attempt = 1; attempt <= 2; attempt++) {
      try {
        await passport.startDlSession(bac, force: attempt > 1);
        if (attempt > 1) {
          _log.info('DL BAC succeeded on retry attempt $attempt');
        }
        return;
      } on PassportError catch (e) {
        final sw = e.code;
        final swCombined = sw == null ? 0 : (sw.sw1 << 8) | sw.sw2;
        if (attempt == 2 || !transient.contains(swCombined)) {
          rethrow;
        }
        _log.warning('DL BAC attempt $attempt failed (SW=${swCombined.toRadixString(16)}), retrying…');
        _safeSetState(() => _status = '🔁 Nouvelle tentative de la session sécurisée…');
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  /// Returns true if [sw] indicates the chip's SM session is broken or
  /// degraded — i.e. subsequent reads will fail until SM is
  /// re-established.
  static bool _swBreaksSm(StatusWord? sw) {
    if (sw == null) return false;
    // 6882 = SM not supported (chip rejecting SM-wrapped commands)
    // 6987 = expected SM data missing (chip thinks our SM is wrong)
    // 6988 = SM data invalid
    if (sw.sw1 == 0x68 && sw.sw2 == 0x82) return true;
    if (sw.sw1 == 0x69 && (sw.sw2 == 0x87 || sw.sw2 == 0x88)) return true;
    return false;
  }

  /// Wraps [Passport.readEfFullBySFI] with SM recovery and live progress.
  /// If the previous call left SM in a bad state, re-init via
  /// [Passport.reinitSmSession] before this read. After this read, if SW
  /// indicates SM broke, we mark a flag so the next call recovers.
  ///
  /// [stepNum] / [stepLabel] feed the user-visible status string so the
  /// 13-second scan shows live progress like
  /// "Lecture 4/6: Photo d'identité (8.4 / 16.0 KB)" instead of a blank
  /// pause.
  Future<Uint8List?> _readFullWithRecovery(
    Passport passport,
    int sfi,
    String label, {
    int maxFileSize = 32768,
    required int stepNum,
    required String stepLabel,
  }) async {
    if (_smBroken) {
      _log.info('SM broken from prior read — reinit before $label');
      _safeSetState(() => _status = '🔄 Reprise de la session sécurisée…');
      try {
        await passport.reinitSmSession();
        _smBroken = false;
      } catch (e) {
        _log.warning('SM reinit failed: $e — proceeding anyway');
      }
    }

    _safeSetState(() => _status = '📖 Lecture $stepNum/6: $stepLabel…');

    String fmtKB(int bytes) {
      if (bytes < 1024) return '$bytes B';
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }

    final result = await passport.readEfFullBySFI(
      sfi,
      chunkSize: 240,
      maxFileSize: maxFileSize,
      onProgress: (bytesRead, totalSize) {
        // Only render a progress count when the file is big enough to be
        // worth it. Sub-1 KB DGs read in one round-trip; the noise hurts
        // more than helps.
        if (totalSize >= 1024 && mounted) {
          _safeSetState(() => _status =
              '📖 Lecture $stepNum/6: $stepLabel '
              '(${fmtKB(bytesRead)} / ${fmtKB(totalSize)})');
        }
      },
    );
    final sw = result.sw;
    final swStr = sw == null
        ? '????'
        : '${_hex2(sw.sw1)}${_hex2(sw.sw2)}';
    if (result.error != null) {
      _log.warning('$label (SFI 0x${sfi.toRadixString(16).padLeft(2, "0")}) error: ${result.error}, SW=$swStr, len=${result.data?.length ?? 0}');
    } else {
      _log.info('$label (SFI 0x${sfi.toRadixString(16).padLeft(2, "0")}) OK SW=$swStr len=${result.data?.length ?? 0}');
    }

    if (_swBreaksSm(sw)) {
      _smBroken = true;
    }
    return result.data;
  }

  /// Sends raw `SELECT BY NAME` APDUs for several candidate AIDs and reports
  /// SW1/SW2 for each. Used when [Passport.startSession] fails — typically
  /// because the chip's applet is not the ICAO 9303 eMRTD applet.
  ///
  /// AIDs probed (most-likely first):
  ///  - ISO/IEC 18013-3 IDL applet  `A0000002480200`
  ///  - ISO/IEC 18013-2 (older)     `A0000002480100`
  ///  - ICAO 9303 eMRTD             `A0000002471001`  (sanity-check)
  ///  - ISO 18013 root RID truncated `A000000248`     (returns first match)
  ///  - GP card manager / ISD       `A000000003000000`
  Future<String> _probeAids() async {
    final candidates = <String, List<int>>{
      'ISO 18013-3 IDL':  [0xA0, 0x00, 0x00, 0x02, 0x48, 0x02, 0x00],
      'ISO 18013-2':      [0xA0, 0x00, 0x00, 0x02, 0x48, 0x01, 0x00],
      'ICAO eMRTD':       [0xA0, 0x00, 0x00, 0x02, 0x47, 0x10, 0x01],
      'ISO 18013 RID':    [0xA0, 0x00, 0x00, 0x02, 0x48],
      'GP Card Manager':  [0xA0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00],
    };

    final lines = <String>[];

    // Re-poll the tag in case the BAC failure left it in an indeterminate state.
    try {
      await _nfc.disconnect();
    } catch (_) {}
    try {
      await _nfc.connect(iosAlertMessage: 'Diagnostic en cours…');
    } catch (e) {
      return 'Reconnect failed: $e';
    }

    for (final entry in candidates.entries) {
      final name = entry.key;
      final aid = entry.value;
      // SELECT BY NAME (P1=04, P2=00 first occurrence, plus Le=00 for any response).
      final apdu = Uint8List.fromList(<int>[
        0x00, 0xA4, 0x04, 0x00, aid.length, ...aid, 0x00,
      ]);
      try {
        final resp = await _nfc.transceive(apdu);
        final swHex = (resp.length >= 2)
            ? _hex2(resp[resp.length - 2]) + _hex2(resp[resp.length - 1])
            : '????';
        final dataLen = (resp.length >= 2) ? resp.length - 2 : 0;
        lines.add('$name (${_hex(aid)}) → SW=$swHex, data=${dataLen}B');
        _log.info('AID probe $name (${_hex(aid)}): SW=$swHex data=${dataLen}B');
      } catch (e) {
        lines.add('$name (${_hex(aid)}) → exception: $e');
      }
    }

    // Try SELECT MF (root) too — some apps read EFs directly off the MF.
    try {
      final apdu = Uint8List.fromList(<int>[0x00, 0xA4, 0x00, 0x00, 0x02, 0x3F, 0x00]);
      final resp = await _nfc.transceive(apdu);
      final swHex = (resp.length >= 2)
          ? _hex2(resp[resp.length - 2]) + _hex2(resp[resp.length - 1])
          : '????';
      lines.add('SELECT MF (3F00) → SW=$swHex');
    } catch (e) {
      lines.add('SELECT MF exception: $e');
    }

    // Try EF.CardAccess (011C) — global file containing PACE info if present.
    try {
      final apdu = Uint8List.fromList(<int>[0x00, 0xA4, 0x02, 0x0C, 0x02, 0x01, 0x1C]);
      final resp = await _nfc.transceive(apdu);
      final swHex = (resp.length >= 2)
          ? _hex2(resp[resp.length - 2]) + _hex2(resp[resp.length - 1])
          : '????';
      lines.add('SELECT EF.CardAccess (011C) → SW=$swHex');
    } catch (e) {
      lines.add('SELECT EF.CardAccess exception: $e');
    }

    return lines.join('\n');
  }

  static String _hex2(int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase();
  static String _hex(List<int> bytes) => bytes.map(_hex2).join();

  /// Extracts the reference face from the decoded chip data. Kept in memory:
  /// the liveness call uploads bytes, so no temp file is needed.
  Future<void> _saveFaceImage() async {
    final dg = (_decoded?['dg5'] ?? _decoded?['dg2']) as Map<String, dynamic>?;
    if (dg == null || dg['result'] != 'True') return;
    final faceB64 = dg['face'] as String?;
    if (faceB64 == null || faceB64.isEmpty) return;
    try {
      _faceBytes = base64Decode(faceB64);
    } catch (e) {
      _log.warning('Image du visage illisible: $e');
    }
  }

  /// Exports the decoded datagroups to a single JSON file and triggers
  /// the system share sheet. The user can save it to Files, send to
  /// themselves on WhatsApp, email, etc. Useful for debugging when a
  /// specific licence doesn't decode as expected.
  Future<void> _shareDgs() async {
    if (_decoded == null) return;
    try {
      final payload = <String, dynamic>{
        'exported_at': DateTime.now().toIso8601String(),
        'app': 'cortixia_kyc',
        'document_type': 'drivinglicence',
        'mrz_inputs': {
          'licence_number': widget.licenceNumber,
          'dob': widget.dob,
          'doe': widget.doe,
        },
        'datagroups': _decoded,
      };
      final jsonStr = const JsonEncoder.withIndent('  ').convert(payload);
      final dir = await getTemporaryDirectory();
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final filePath = path.join(dir.path, 'cortixia_dl_$ts.json');
      final file = File(filePath);
      await file.writeAsString(jsonStr);
      await Share.shareXFiles(
        [XFile(filePath, mimeType: 'application/json')],
        subject: 'Cortixia KYC — Données du permis',
        text: 'Données extraites du permis de conduire.',
      );
    } catch (e, st) {
      _log.warning('Échec de l\'export des DGs: $e\n$st');
      _safeSetState(() {
        _status = '❌ Échec de l\'export: $e';
      });
    }
  }

  Future<void> _startFaceMatching() async {
    if (_faceBytes == null) {
      setState(() {
        _status = 'Image du visage non disponible pour la comparaison';
      });
      return;
    }

    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FaceMatchingPage(
        cameras: widget.cameras,
        referenceFace: _faceBytes!,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFFFFF),
      appBar: AppBar(
        title: const Text('Lecture NFC - Permis'),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFF9FAFB),
              Color(0xFFFFFFFF),
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_decoded == null) ...[
                const SizedBox(height: 16),
                Center(
                  child: AnimatedBuilder(
                    animation: _pulseAnimation,
                    builder: (context, child) {
                      return Transform.scale(
                        scale: _reading ? _pulseAnimation.value : 1.0,
                        child: Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            gradient: _reading
                                ? const LinearGradient(
                              colors: [_accent, _accentDark],
                            )
                                : null,
                            color: _reading ? null : Colors.grey.withOpacity(0.2),
                            shape: BoxShape.circle,
                            boxShadow: _reading
                                ? [
                                    BoxShadow(
                                      color: _accent.withOpacity(0.5),
                                      blurRadius: 20,
                                      offset: const Offset(0, 10),
                                    ),
                                  ]
                                : [],
                          ),
                          child: Icon(
                            Icons.nfc,
                            size: 48,
                            color: _reading ? Colors.white : Colors.grey,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _reading
                        ? _accent.withOpacity(0.1)
                        : const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _reading
                          ? _accent.withOpacity(0.5)
                          : const Color(0xFFE5E7EB),
                    ),
                  ),
                  child: Text(
                    _status.isEmpty ? 'Prêt à scanner' : _status,
                    style: TextStyle(
                      fontSize: 14,
                      color: _reading ? const Color(0xFF111827) : const Color(0xFF6B7280),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 12),
              ],

              Container(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [_accent, _accentDark],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: _accent.withOpacity(0.4),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ElevatedButton.icon(
                  onPressed: _reading ? null : _checkNfcAndScan,
                  icon: Icon(_reading ? Icons.hourglass_empty : Icons.nfc),
                  label: Text(_reading ? 'Lecture en cours…' : 'Commencer la lecture'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),

              if (_showFaceMatching) ...[
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF0D9488), Color(0xFF0F766E)],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF0D9488).withOpacity(0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: ElevatedButton.icon(
                    onPressed: _startFaceMatching,
                    icon: const Icon(Icons.face),
                    label: const Text('Vérification biométrique'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
              ],

              if (_decoded != null && KycFlowHost.of(context).config.debugMode) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _shareDgs,
                  icon: const Icon(Icons.download),
                  label: const Text('Télécharger les données'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _accentDark,
                    side: const BorderSide(color: _accent, width: 1.5),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 24),

              Expanded(
                child: ListView(
                  children: [
                    if (_sfiDump != null && KycFlowHost.of(context).config.debugMode) ...[
                      Card(
                        color: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: const BorderSide(color: Color(0xFFA7F3D0)),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: const [
                                  Icon(Icons.list_alt, color: Color(0xFF059669)),
                                  SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      'Énumération des fichiers (SFI map)',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                        color: Color(0xFF111827),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'BAC réussi. Voici les fichiers exposés par l\'applet IDL — '
                                'partagez ce résultat pour qu\'on puisse écrire le décodeur '
                                'spécifique au permis algérien.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF6B7280),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF3F4F6),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: SelectableText(
                                  _sfiDump!,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    color: Color(0xFF111827),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'SW=9000 = lecture OK. SW=6A82 = fichier inexistant. '
                                'tag = premier octet du fichier (en TLV BER, '
                                'identifie le type de DG).',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF9CA3AF),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    if (_probeReport != null && KycFlowHost.of(context).config.debugMode) ...[
                      Card(
                        color: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: const BorderSide(color: Color(0xFFFFE4B5)),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: const [
                                  Icon(Icons.bug_report, color: Color(0xFFD97706)),
                                  SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      'Diagnostic NFC (AID probe)',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                        color: Color(0xFF111827),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'La puce a refusé l\'AID eMRTD ICAO. Voici la réponse de la puce '
                                'à différents AIDs candidats — partagez ce résultat pour identifier '
                                'l\'applet du permis.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF6B7280),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF3F4F6),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: SelectableText(
                                  _probeReport!,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    color: Color(0xFF111827),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'SW=9000 = succès. SW=6A82 = "fichier introuvable". '
                                'SW=6A86 = "P1/P2 incorrect".',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF9CA3AF),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    if (_decoded != null) ...[
                      _decodedSection(_decoded!),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _decodedSection(Map<String, dynamic> data) {
    List<Widget> tiles = [];

    // Personal info — pulled from DG1 (Latin), DG11 (sex+place), DG12 (NIN),
    // DG13 (Arabic), in that order so each can fill in fields the previous
    // didn't have.
    final dg1 = data['dg1'] as Map<String, dynamic>?;
    final dg11 = data['dg11'] as Map<String, dynamic>?;
    final dg12 = data['dg12'] as Map<String, dynamic>?;
    final dg13 = data['dg13'] as Map<String, dynamic>?;

    String pick(String key) {
      for (final src in [dg1, dg11, dg12, dg13]) {
        if (src == null) continue;
        final v = src[key];
        if (v is String && v.isNotEmpty) return v;
      }
      return '';
    }

    if (dg1 != null || dg11 != null || dg12 != null || dg13 != null) {
      tiles.add(Card(
        color: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.person, color: _accent),
                  SizedBox(width: 12),
                  Text(
                    'Informations personnelles',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Color(0xFF111827),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _infoRow('👤 Prénom (Latin)', pick('name_latin')),
              _infoRow('👤 Prénom (Arabe)', pick('name_arabic')),
              _infoRow('👥 Nom (Latin)', pick('surname_latin')),
              _infoRow('👥 Nom (Arabe)', pick('surname_arabic')),
              _infoRow('🎂 Date de naissance', pick('birth_date')),
              _infoRow('📍 Lieu de naissance', pick('birthplace_latin')),
              _infoRow('🌍 Lieu (Arabe)', pick('place_arabic')),
              _infoRow('⚧ Sexe', pick('sex_latin')),
              _infoRow('🩸 Groupe sanguin', pick('blood_type')),
              _infoRow('🆔 NIN', pick('nin')),
            ],
          ),
        ),
      ));
    }

    // Document info — DG1 carries licence number, dates, commune, categories.
    if (dg1 != null && dg1['result'] == 'True') {
      tiles.add(Card(
        color: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.directions_car, color: _accentDark),
                  SizedBox(width: 12),
                  Text(
                    'Informations du permis',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Color(0xFF111827),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _infoRow('🚗 N° permis', dg1['licence_number'] ?? ''),
              _infoRow('🏘 Commune', dg1['commune_latin'] ?? ''),
              _infoRow('🌐 Nationalité', dg1['nationality'] ?? ''),
              _infoRow('📅 Date d\'émission', dg1['issue_date'] ?? ''),
              _infoRow('⏰ Date d\'expiration', dg1['expiry_date'] ?? ''),
              _infoRow('📋 Catégories (hex)', dg1['categories'] ?? ''),
            ],
          ),
        ),
      ));
    }

    // Portrait — IDL stores it as 'dg5' (tag 0x65). Old key 'dg2' kept for fallback.
    final face = (data['dg5'] ?? data['dg2']) as Map<String, dynamic>?;
    if (face != null && face['result'] == 'True') {
      tiles.add(Card(
        color: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.photo_camera, color: _accent),
                  SizedBox(width: 12),
                  Text(
                    'Photo d\'identité',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Color(0xFF111827),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _buildImageFromBase64(face['face'] as String?, 'Photo d\'identité'),
            ],
          ),
        ),
      ));
    }

    final sig = data['dg7'] as Map<String, dynamic>?;
    if (sig != null && sig['result'] == 'True') {
      tiles.add(Card(
        color: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.draw, color: _accentDark),
                  SizedBox(width: 12),
                  Text(
                    'Signature',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Color(0xFF111827),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _buildImageFromBase64(sig['signature'] as String?, 'Signature'),
            ],
          ),
        ),
      ));
    }

    return Column(children: tiles);
  }

  Widget _infoRow(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 13,
                color: Color(0xFF6B7280),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF111827),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageFromBase64(String? base64String, String fallbackText) {
    if (base64String != null && base64String.isNotEmpty) {
      try {
        final bytes = base64Decode(base64String);
        return Center(
          child: Container(
            constraints: const BoxConstraints(maxHeight: 200, maxWidth: 200),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _accent.withOpacity(0.3)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'Erreur d\'affichage de $fallbackText',
                      style: const TextStyle(color: Color(0xFF9CA3AF)),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      } catch (e) {
        return Text(
          'Erreur de décodage de $fallbackText: $e',
          style: const TextStyle(color: Color(0xFF9CA3AF)),
        );
      }
    } else {
      return Container(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Text(
            '$fallbackText non disponible',
            style: const TextStyle(color: Color(0xFF9CA3AF)),
          ),
        ),
      );
    }
  }
}
