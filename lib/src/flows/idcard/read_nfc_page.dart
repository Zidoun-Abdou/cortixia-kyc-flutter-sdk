import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dmrtd/dmrtd.dart';
import 'package:dmrtd/extensions.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:camera/camera.dart';
import '../liveness/face_matching_page.dart';
import '../../models/kyc_models.dart';
import '../kyc_flow_host.dart';

class MrtdData {
  EfDG2? dg2;
  EfDG7? dg7;
  EfDG11? dg11;
  EfDG12? dg12;
}

class ReadNfcPage extends StatefulWidget {
  final List<CameraDescription> cameras;
  final String idNumber;
  final String dob;
  final String doe;

  const ReadNfcPage({
    super.key,
    required this.cameras,
    required this.idNumber,
    required this.dob,
    required this.doe
  });

  @override
  State<ReadNfcPage> createState() => _ReadNfcPageState();
}

class _ReadNfcPageState extends State<ReadNfcPage> with SingleTickerProviderStateMixin {
  final _log = Logger('cortixiakyc.nfc');
  final _nfc = NfcProvider();
  bool _reading = false;
  String _status = '';
  MrtdData? _data;
  Map<String, dynamic>? _decoded;
  String? _faceImagePath;
  bool _showFaceMatching = false;
  late AnimationController _animationController;
  late Animation<double> _pulseAnimation;

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

  Future<void> _readMRTD() async {
    setState(() {
      _reading = true;
      _status = '📱 Approchez la carte d\'identité du téléphone…';
      _data = null;
      _decoded = null;
    });

    try {
      await _nfc.connect();
      final passport = Passport(_nfc);

      setState(() => _status = '🔐 Démarrage de la session sécurisée…');

      final dob = DateTime.parse(widget.dob);
      final doe = DateTime.parse(widget.doe);
      final bac = DBAKeys(widget.idNumber, dob, doe);

      await passport.startSession(bac);

      final out = MrtdData();

      Future<T?> tryRead<T>(Future<T> Function() reader) async {
        try {
          return await reader();
        } catch (e) {
          _log.warning('Erreur lors de la lecture du groupe de données: $e');
          return null;
        }
      }

      setState(() => _status = '📖 Lecture des groupes de données…');

      out.dg2 = await tryRead(() => passport.readEfDG2());
      out.dg7 = await tryRead(() => passport.readEfDG7());
      out.dg11 = await tryRead(() => passport.readEfDG11());
      out.dg12 = await tryRead(() => passport.readEfDG12());

      setState(() {
        _data = out;
        _status = '✅ Terminé. Décodage des données…';
      });

      await _decodeLocally();

    } catch (e, st) {
      _log.warning('Échec de la lecture: $e\n$st');
      setState(() {
        _status = '❌ Erreur de lecture: ${e.toString()}';
      });
    } finally {
      try {
        await _nfc.disconnect(iosAlertMessage: 'Terminé');
      } catch (_) {}
      setState(() {
        _reading = false;
      });
    }
  }

  Future<void> _decodeLocally() async {
    if (_data == null) return;

    setState(() {
      _status = '🔄 Décodage des données…';
    });

    Uint8List? bytesOf(dynamic dg) {
      try {
        if (dg == null) return null;
        return (dg as dynamic).toBytes() as Uint8List;
      } catch (e) {
        _log.warning('Erreur de conversion DG en bytes: $e');
        return null;
      }
    }

    try {
      final host = KycFlowHost.of(context);
      final data = await host.backend.decode(
        documentType: 'idcard',
        sessionId: host.sessionId,
        datagroups: {
          if (bytesOf(_data!.dg2) != null) 'dg2': bytesOf(_data!.dg2)!,
          if (bytesOf(_data!.dg7) != null) 'dg7': bytesOf(_data!.dg7)!,
          if (bytesOf(_data!.dg11) != null) 'dg11': bytesOf(_data!.dg11)!,
          if (bytesOf(_data!.dg12) != null) 'dg12': bytesOf(_data!.dg12)!,
        },
      );

      setState(() {
        _decoded = data;
        _status = '✅ Décodé avec succès!';
      });

      await _saveFaceImage();

      if (!mounted) return;
      final decision = await host.documentRead(
        data,
        mrzDocumentNumber: widget.idNumber,
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
          setState(() {
            _showFaceMatching = true;
          });
      }
    } on KycException catch (e) {
      // Licence/quota problem or the decode service is unavailable: the flow
      // cannot produce a result, so end it with a typed error.
      _log.warning('Décodage impossible: ${e.message}');
      if (!mounted) return;
      setState(() => _status = '❌ ${e.message}');
      KycFlowHost.of(context).completeFailed(e);
    } catch (e) {
      _log.warning('Erreur de décodage: $e');
      setState(() {
        _status = '❌ Erreur de décodage: $e';
      });
    }
  }

  Future<void> _saveFaceImage() async {
    final dg2 = _decoded?['dg2'] as Map<String, dynamic>?;
    if (dg2 != null && dg2['result'] == 'True') {
      final faceB64 = dg2['face'] as String?;
      if (faceB64 != null && faceB64.isNotEmpty) {
        try {
          final bytes = base64Decode(faceB64);
          final directory = await getTemporaryDirectory();
          final filePath = path.join(directory.path, 'face_from_id.jpg');
          final file = File(filePath);
          await file.writeAsBytes(bytes);
          _faceImagePath = filePath;
        } catch (e) {
          _log.warning('Erreur lors de la sauvegarde de l\'image du visage: $e');
        }
      }
    }
  }

  Future<void> _startFaceMatching() async {
    if (_faceImagePath == null) {
      setState(() {
        _status = 'Image du visage non disponible pour la comparaison';
      });
      return;
    }

    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FaceMatchingPage(
        cameras: widget.cameras,
        faceImagePath: _faceImagePath!,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFFFFF),
      appBar: AppBar(
        title: const Text('Lecture NFC'),
        backgroundColor: const Color(0xFF1E3A5F),
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
              // NFC Animation and Status
              if (!(_data != null && _decoded != null)) ...[
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
                              colors: [Color(0xFF1E3A5F), Color(0xFF0D9488)],
                            )
                                : null,
                            color: _reading ? null : Colors.grey.withOpacity(0.2),
                            shape: BoxShape.circle,
                            boxShadow: _reading ? [
                              BoxShadow(
                                color: const Color(0xFF1E3A5F).withOpacity(0.5),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                              ),
                            ] : [],
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
                        ? const Color(0xFF1E3A5F).withOpacity(0.1)
                        : const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _reading
                          ? const Color(0xFF1E3A5F).withOpacity(0.5)
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

              // Start/Restart Button
              Container(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1E3A5F), Color(0xFF0D9488)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF1E3A5F).withOpacity(0.4),
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

              const SizedBox(height: 24),

              // Results
              Expanded(
                child: ListView(
                  children: [
                    if (_data != null) ...[
                      Card(
                        color: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: const [
                                  Icon(Icons.storage, color: Color(0xFF1E3A5F)),
                                  SizedBox(width: 12),
                                  Text(
                                    'Données brutes lues',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: Color(0xFF111827),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _dgTile('DG2 - Image du visage', _data!.dg2),
                              _dgTile('DG7 - Signature', _data!.dg7),
                              _dgTile('DG11 - Données personnelles', _data!.dg11),
                              _dgTile('DG12 - Données du document', _data!.dg12),
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

  Widget _dgTile(String name, Object? dg) {
    final ok = dg != null;
    int? len;
    if (ok) {
      try {
        len = ((dg as dynamic).toBytes() as Uint8List).length;
      } catch (_) {}
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.cancel,
            color: ok ? const Color(0xFF0D9488) : const Color(0xFFFF6B6B),
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(color: Color(0xFF374151)),
            ),
          ),
          if (ok && len != null)
            Text(
              '$len octets',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF9CA3AF),
              ),
            ),
        ],
      ),
    );
  }

  Widget _decodedSection(Map<String, dynamic> data) {
    List<Widget> tiles = [];

    // DG11 Personal Data
    final dg11 = data['dg11'] as Map<String, dynamic>?;
    if (dg11 != null && dg11['result'] == 'True') {
      tiles.add(Card(
        color: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.person, color: Color(0xFF1E3A5F)),
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
              _infoRow('👤 Prénom (Latin)', dg11['name_latin'] ?? ''),
              _infoRow('👤 Prénom (Arabe)', dg11['name_arabic'] ?? ''),
              _infoRow('👥 Nom (Latin)', dg11['surname_latin'] ?? ''),
              _infoRow('👥 Nom (Arabe)', dg11['surname_arabic'] ?? ''),
              _infoRow('🎂 Date de naissance', dg11['birth_date'] ?? ''),
              _infoRow('📍 Lieu de naissance (Latin)', dg11['birthplace_latin'] ?? ''),
              _infoRow('📍 Lieu de naissance (Arabe)', dg11['birthplace_arabic'] ?? ''),
              _infoRow('⚧ Sexe', dg11['sex_latin'] ?? ''),
              _infoRow('🩸 Groupe sanguin', dg11['blood_type'] ?? ''),
              _infoRow('🆔 NIN', dg11['nin'] ?? ''),
            ],
          ),
        ),
      ));
    }

    // DG12 Document Data
    final dg12 = data['dg12'] as Map<String, dynamic>?;
    if (dg12 != null && dg12['result'] == 'True') {
      tiles.add(Card(
        color: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.credit_card, color: Color(0xFF0D9488)),
                  SizedBox(width: 12),
                  Text(
                    'Informations du document',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Color(0xFF111827),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _infoRow('🏛 Daïra', dg12['daira'] ?? ''),
              _infoRow('🏘 Baladia (Latin)', dg12['baladia_latin'] ?? ''),
              _infoRow('🏘 Baladia (Arabe)', dg12['baladia_arabic'] ?? ''),
              _infoRow('📅 Date d\'émission', dg12['delivery_date'] ?? ''),
              _infoRow('⏰ Date d\'expiration', dg12['expiry_date'] ?? ''),
            ],
          ),
        ),
      ));
    }

    // DG2 Face Image
    final dg2 = data['dg2'] as Map<String, dynamic>?;
    if (dg2 != null && dg2['result'] == 'True') {
      tiles.add(Card(
        color: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.photo_camera, color: Color(0xFF1E3A5F)),
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
              _buildImageFromBase64(dg2['face'] as String?, 'Photo d\'identité'),
            ],
          ),
        ),
      ));
    }

    // DG7 Signature
    final dg7 = data['dg7'] as Map<String, dynamic>?;
    if (dg7 != null && dg7['result'] == 'True') {
      tiles.add(Card(
        color: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.draw, color: Color(0xFF0D9488)),
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
              _buildImageFromBase64(dg7['signature'] as String?, 'Signature'),
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
              border: Border.all(color: const Color(0xFF1E3A5F).withOpacity(0.3)),
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