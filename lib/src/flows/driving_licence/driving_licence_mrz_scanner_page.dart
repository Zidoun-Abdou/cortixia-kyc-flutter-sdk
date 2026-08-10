import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../../models/kyc_models.dart';
import '../kyc_flow_host.dart';
import '../mrz_prefilter.dart';
import '../helpers.dart';
import 'driving_licence_read_nfc_page.dart';

class DrivingLicenceMrzScannerPage extends StatefulWidget {
  final List<CameraDescription> cameras;

  const DrivingLicenceMrzScannerPage({super.key, required this.cameras});

  @override
  State<DrivingLicenceMrzScannerPage> createState() => _DrivingLicenceMrzScannerPageState();
}

class _DrivingLicenceMrzScannerPageState extends State<DrivingLicenceMrzScannerPage> with WidgetsBindingObserver {
  late CameraController cameraController;
  bool isCameraInitialized = false;
  bool isCameraDisposed = false;
  late TextRecognizer textRecognizer;
  List<String> filteredStrings = [];
  CameraImage? cameraImage;
  String nfcKeys = '';
  DateTime? lastProcessed;
  final int throttleIntervalMs = 500;
  bool isProcessingComplete = false;
  bool isStreaming = false;
  bool isNavigatingAway = false;
  /// Normalised OCR lines of the accepted candidate.
  List<String> rawMrzLines = const [];
  String? mrzError;

  Map<String, String>? extractedData;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeCamera();
    textRecognizer.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        _closeCamera();
        break;
      case AppLifecycleState.resumed:
        if (!isNavigatingAway && !isProcessingComplete) {
          _reopenCamera();
        }
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> initializeCamera() async {
    if (isCameraDisposed) return;

    try {
      final cameras = widget.cameras;

      if (cameras.isNotEmpty) {
        cameraController = CameraController(
          cameras[0],
          ResolutionPreset.max,
          enableAudio: false,
          imageFormatGroup: ImageFormatGroup.nv21,
        );

        await cameraController.initialize();

        if (mounted && !isCameraDisposed) {
          setState(() {
            isCameraInitialized = true;
          });

          if (!isProcessingComplete) {
            _startImageStream();
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Erreur: Aucune caméra disponible")),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erreur caméra: Échec de l'initialisation: $e")),
        );
      }
    }
  }

  void _startImageStream() {
    if (!isCameraInitialized || isCameraDisposed || isStreaming) return;

    try {
      cameraController.startImageStream((image) async {
        if (!isStreaming) {
          isStreaming = true;
        }
        handleCameraFrame(image);
      });
    } catch (e) {
      print('Erreur lors du démarrage du flux d\'image: $e');
    }
  }

  Future<void> _stopImageStream() async {
    if (!isStreaming || isCameraDisposed) return;

    try {
      await cameraController.stopImageStream();
      isStreaming = false;
    } catch (e) {
      isStreaming = false;
    }
  }

  Future<void> _closeCamera() async {
    if (isCameraDisposed || !isCameraInitialized) return;

    // Claim the camera BEFORE the first await. These flags track the camera,
    // not the widget, so they must be set unconditionally — the previous
    // version only set them inside `if (mounted)`, which meant navigating away
    // (the common case) left isCameraDisposed false and let the widget's
    // dispose() dispose the controller a SECOND time. A double dispose surfaces
    // as `CameraCaptureSession.close()` on a null reference, which either
    // crashes the app or wedges the camera plugin on the platform thread — and
    // a wedged platform thread hangs every later MethodChannel call, including
    // the NFC availability check, so the "Lire avec NFC" button silently does
    // nothing until the app is restarted.
    isCameraDisposed = true;
    isCameraInitialized = false;

    try {
      await _stopImageStream();
      await cameraController.dispose();
    } catch (e) {
      print('Erreur lors de la fermeture de la caméra: $e');
    }

    if (mounted) setState(() {});
  }

  Future<void> _reopenCamera() async {
    if (!isCameraDisposed || !mounted) return;

    setState(() {
      isCameraDisposed = false;
    });

    await initializeCamera();
  }

  /// Synchronous teardown for `dispose()`, which cannot await.
  ///
  /// Idempotent with [_closeCamera]: whichever runs first claims the camera by
  /// setting the flag before touching the controller, so the other becomes a
  /// no-op. Disposing a CameraController twice is what produced the null
  /// CameraCaptureSession crash.
  void _disposeCamera() {
    if (isCameraDisposed) return;
    isCameraDisposed = true;
    isCameraInitialized = false;

    try {
      if (isStreaming) {
        cameraController.stopImageStream();
        isStreaming = false;
      }
      cameraController.dispose();
    } catch (e) {
      print('Erreur lors de la suppression de la caméra: $e');
    }
  }

  Future<void> handleCameraFrame(CameraImage image) async {
    if (isProcessingComplete || isCameraDisposed) {
      return;
    }

    final now = DateTime.now();

    if (lastProcessed != null &&
        now.difference(lastProcessed!) < Duration(milliseconds: throttleIntervalMs)) {
      return;
    }
    lastProcessed = now;

    InputImageRotation rotation = InputImageRotationValue.fromRawValue(
        cameraController.description.sensorOrientation) ??
        InputImageRotation.rotation0deg;
    cameraImage = image;
    final inputImage = await convertNV21CameraImageToInputImage(image, rotation);

    if (inputImage != null) {
      try {
        final recognizedText = await textRecognizer.processImage(inputImage);
        List<String> extractedLines = [];
        Rect roi = setRoi();

        for (int index = 0; index < recognizedText.blocks.length; index++) {
          TextBlock block = recognizedText.blocks[index];

          if (roi.contains(Offset(block.boundingBox.left.toDouble(),
              block.boundingBox.top.toDouble())) &&
              roi.contains(Offset(block.boundingBox.right.toDouble(),
                  block.boundingBox.bottom.toDouble()))) {

            String blockText = block.text.replaceAll(' ', '').toUpperCase();
            // Driving licence MRZ starts with DL (TD1-style 3-line format)
            if (blockText.startsWith('DLDZ') || blockText.startsWith('DL')) {
              for (TextLine line in block.lines) {
                String text = line.text.replaceAll(' ', '').toUpperCase();
                extractedLines.add(text);
              }

              if (extractedLines.length < 3) {
                return;
              }

              filteredStrings = filterValidStrings(extractedLines);

              if (filteredStrings.length < 3) {
                return;
              }

              await handleMrzText();
            }
          }
        }
      } catch (e) {
        print('Erreur lors du traitement de l\'image: $e');
      }
    }
  }

  List<String> filterValidStrings(List<String> inputStrings) {
    RegExp validPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9\s<«()*]*$');
    RegExp containsLetters = RegExp(r'[A-Za-z]');

    return inputStrings.where((str) {
      if (!validPattern.hasMatch(str)) return false;
      return containsLetters.hasMatch(str);
    }).toList();
  }

  Future<void> handleMrzText() async {
    try {
      List<String> processLines = [];
      List<String> lines = filteredStrings;
      int index = lines.indexWhere((line) => line.startsWith('DL'));
      if (index >= 0) {
        processLines = lines.sublist(index).map((e) => e.trim()).toList();
      }

      if (processLines.length >= 3) {
        final mrzData = extractMrzData(processLines);

        if (mrzData == null) {
          throw Exception("Données MRZ invalides.");
        }

        setState(() {
          isProcessingComplete = true;
          extractedData = mrzData;
          rawMrzLines = processLines;
          nfcKeys = displayNFCKeys(
            licenceNumber: mrzData['licenceNumber']!,
            birthDate: mrzData['birthDate']!,
            expiryDate: mrzData['expiryDate']!,
          );
        });

        await _stopImageStream();
      }
    } catch (error) {
      print("Erreur lors du traitement du texte: $error");
    }
  }

  Map<String, String>? extractMrzData(List<String> processLines) {
    // Driving licence MRZ (ISO/IEC 18013, 3 lines x 30 chars):
    // Line 1:  DL DZA <licenceNumber 9 chars> <CD> <padding<<<>
    //          ex: DLDZAA073949334<<<<<<<<<<<<<<
    // Line 2:  <DOB YYMMDD><CD><sex><expiry YYMMDD><CD><DZA><padding><overall CD>
    //          ex: 9503124M3604225DZA<<<<<<<<<<<4
    // Line 3:  <SURNAME<<GIVEN<NAMES< padded with <>
    String firstLine = processLines[0];
    String secondLine = processLines[1];

    if (firstLine.length < 14) {
      throw Exception("Première ligne MRZ trop courte");
    }
    if (secondLine.length < 15) {
      throw Exception("Deuxième ligne MRZ trop courte");
    }

    // Line 1: positions 5..14 = licence number (9 chars)
    String licenceNumber = firstLine.substring(5, 14);

    // Line 2: 0..6 = DOB, 7 = sex, 8..14 = expiry (with check digits at 6 and 14)
    String birthDate = secondLine.substring(0, 6);
    String formattedBirthDate = formatMrzDate(birthDate, 'b');
    String expiryDate = secondLine.substring(8, 14);
    String formattedExpiryDate = formatMrzDate(expiryDate, 'e');

    if (formattedBirthDate.isEmpty) {
      throw Exception("Format de date de naissance invalide");
    }

    if (formattedExpiryDate.isEmpty) {
      throw Exception("Format de date d'expiration invalide");
    }

    return {
      'licenceNumber': licenceNumber,
      'birthDate': formattedBirthDate,
      'expiryDate': formattedExpiryDate,
    };
  }

  String displayNFCKeys({
    required String licenceNumber,
    required String birthDate,
    required String expiryDate,
  }) {
    return '''
N° permis: $licenceNumber
Date de naissance: $birthDate
Date d'expiration: $expiryDate
  ''';
  }

  Rect setRoi() {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final cameraWidth = cameraController.value.previewSize!.height;
    final cameraHeight = cameraController.value.previewSize!.width;

    final roiWidth = screenWidth * 0.9;
    final roiHeight = screenHeight * 0.3;
    final roiTop = screenHeight * 0.35;
    final roiLeft = screenWidth * 0.05;

    final roiRect = Rect.fromLTRB(
      roiLeft * cameraWidth / screenWidth,
      roiTop * cameraHeight / screenHeight,
      (roiLeft + roiWidth) * cameraWidth / screenWidth,
      (roiTop + roiHeight) * cameraHeight / screenHeight,
    );
    return roiRect;
  }

  void restartScanning() {
    setState(() {
      isProcessingComplete = false;
      extractedData = null;
      nfcKeys = '';
      isNavigatingAway = false;
    });

    if (isCameraDisposed) {
      _reopenCamera();
    } else if (isCameraInitialized && !isStreaming) {
      _startImageStream();
    }
  }

  /// Validates the detected MRZ on the server, then either returns it
  /// (mrzOnly) or continues to the chip read (full flow).
  ///
  /// The server is the only authority on whether an MRZ is valid: parsing it
  /// locally would defeat the pack it is meant to gate.
  Future<void> navigateToNfcReader() async {
    if (extractedData == null || isNavigatingAway) return;
    isNavigatingAway = true;
    await _closeCamera();
    if (!mounted) { isNavigatingAway = false; return; }

    final host = KycFlowHost.of(context);
    MrzResult mrz;
    try {
      final payload = await host.backend.parseMrz(
        documentType: KycDocumentType.drivingLicence.wire,
        lines: MrzPrefilter.normalise(rawMrzLines),
        sessionId: host.sessionId,
      );
      mrz = MrzResult.fromJson(KycDocumentType.drivingLicence, payload);
      host.mrz = mrz;
    } on KycException catch (e) {
      if (!mounted) return;
      // The camera was torn down before this call, so without restarting the
      // scan the user is stranded on a frozen preview with no way forward.
      // That, plus mrzError never being rendered, is why a rejected MRZ looked
      // like the button doing nothing at all: tapping again just repeated a
      // failure nobody could see.
      isNavigatingAway = false;
      setState(() => mrzError = e.message);
      restartScanning();
      return;
    }

    if (!mounted) return;
    if (!host.continuesToChip) {
      host.completeSuccess();
      return;
    }

    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DrivingLicenceReadNfcPage(
        cameras: widget.cameras,
        licenceNumber: mrz.documentNumber,
        dob: mrz.birthDate,
        doe: mrz.expiryDate,
      ),
    ));
    // Back from the chip screen (the user cancelled, or the read failed and
    // they popped). The camera was torn down before navigating, so without
    // this the scanner comes back to a dead preview and looks frozen.
    if (!mounted) return;
    isNavigatingAway = false;
    restartScanning();
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF059669);
    const accentDark = Color(0xFF047857);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scanner MRZ - Permis'),
        backgroundColor: accent,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: Stack(
        children: [
          if (isCameraInitialized && !isProcessingComplete)
            Positioned.fill(
              child: CameraPreview(cameraController),
            ),

          if (!isCameraInitialized && !isProcessingComplete)
            const Center(
              child: CircularProgressIndicator(),
            ),

          if (isCameraInitialized && !isProcessingComplete)
            Positioned.fill(
              child: CustomPaint(
                painter: _DrivingLicenceRoiOverlayPainter(),
              ),
            ),

          if (isCameraInitialized && !isProcessingComplete)
            Positioned(
              top: MediaQuery.of(context).size.height * 0.35,
              left: MediaQuery.of(context).size.width * 0.05,
              width: MediaQuery.of(context).size.width * 0.9,
              height: MediaQuery.of(context).size.height * 0.3,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.transparent),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.directions_car,
                      color: Colors.white.withOpacity(0.3),
                      size: 48,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Zone MRZ Permis (verso)',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.3),
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          if (!isProcessingComplete)
            Positioned(
              top: 50,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Placez la zone MRZ du verso de votre permis dans le cadre',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Scan automatique en cours',
                          style: TextStyle(
                            color: accent,
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

          if (isProcessingComplete && extractedData != null)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      accent.withOpacity(0.1),
                      Colors.white,
                    ],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check_circle,
                          color: Colors.green,
                          size: 60,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'MRZ du permis scanné avec succès!',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 30),
                      Card(
                        color: Colors.white,
                        elevation: 4,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: const [
                                  Icon(
                                    Icons.info_outline,
                                    color: accent,
                                  ),
                                  SizedBox(width: 12),
                                  Text(
                                    'Informations extraites',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF111827),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              _buildInfoRow('🚗 N° Permis', extractedData!['licenceNumber']!),
                              const SizedBox(height: 8),
                              _buildInfoRow('🎂 Date de naissance', extractedData!['birthDate']!),
                              const SizedBox(height: 8),
                              _buildInfoRow('📅 Date d\'expiration', extractedData!['expiryDate']!),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 30),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: restartScanning,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Scanner à nouveau'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.grey[600],
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: navigateToNfcReader,
                              icon: const Icon(Icons.nfc),
                              label: const Text('Lire avec NFC'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: accentDark,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Étape suivante: Lecture NFC pour accéder aux données complètes',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Server-side MRZ rejection. Rendered LAST so it paints above the
          // camera preview. This used to be assigned to `mrzError` and never
          // rendered at all, which made a rejected read indistinguishable from
          // a dead button — the worst way for this to fail, because the user
          // cannot tell whether to retry, reposition, or give up.
          if (mrzError != null)
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: Material(
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(12),
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Color(0xFFB91C1C)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          mrzError!,
                          style: const TextStyle(
                            color: Color(0xFF7F1D1D),
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18, color: Color(0xFF7F1D1D)),
                        onPressed: () => setState(() => mrzError = null),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6).withOpacity(0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: const Color(0xFF059669).withOpacity(0.15),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 14,
                color: Color(0xFF6B7280),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              value,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: Color(0xFF111827),
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _DrivingLicenceRoiOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final roiWidth = size.width * 0.9;
    final roiHeight = size.height * 0.3;
    final roiTop = size.height * 0.35;
    final roiLeft = size.width * 0.05;

    final roiRect = Rect.fromLTRB(
      roiLeft, roiTop, roiLeft + roiWidth, roiTop + roiHeight,
    );

    final path = Path()
      ..addRect(Rect.fromLTRB(0, 0, size.width, size.height))
      ..addRect(roiRect)
      ..fillType = PathFillType.evenOdd;

    final overlayPaint = Paint()
      ..color = Colors.black.withOpacity(0.6)
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, overlayPaint);

    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    canvas.drawRRect(
      RRect.fromRectAndRadius(roiRect, const Radius.circular(12)),
      borderPaint,
    );

    final glowPaint = Paint()
      ..color = Colors.white.withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 4);

    canvas.drawRRect(
      RRect.fromRectAndRadius(roiRect, const Radius.circular(12)),
      glowPaint,
    );

    final cornerLength = 30.0;
    final cornerPaint = Paint()
      ..color = const Color(0xFF059669)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(roiRect.left, roiRect.top + cornerLength), Offset(roiRect.left, roiRect.top), cornerPaint);
    canvas.drawLine(Offset(roiRect.left, roiRect.top), Offset(roiRect.left + cornerLength, roiRect.top), cornerPaint);
    canvas.drawLine(Offset(roiRect.right - cornerLength, roiRect.top), Offset(roiRect.right, roiRect.top), cornerPaint);
    canvas.drawLine(Offset(roiRect.right, roiRect.top), Offset(roiRect.right, roiRect.top + cornerLength), cornerPaint);
    canvas.drawLine(Offset(roiRect.left, roiRect.bottom - cornerLength), Offset(roiRect.left, roiRect.bottom), cornerPaint);
    canvas.drawLine(Offset(roiRect.left, roiRect.bottom), Offset(roiRect.left + cornerLength, roiRect.bottom), cornerPaint);
    canvas.drawLine(Offset(roiRect.right - cornerLength, roiRect.bottom), Offset(roiRect.right, roiRect.bottom), cornerPaint);
    canvas.drawLine(Offset(roiRect.right, roiRect.bottom - cornerLength), Offset(roiRect.right, roiRect.bottom), cornerPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
