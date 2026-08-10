import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'dart:io';
import 'dart:typed_data';
import '../../models/kyc_models.dart';
import '../kyc_flow_host.dart';

class FaceMatchingPage extends StatefulWidget {
  final List<CameraDescription> cameras;

  /// Reference face as JPEG bytes (from the chip, or supplied by the host).
  final Uint8List referenceFace;

  const FaceMatchingPage({
    super.key,
    required this.cameras,
    required this.referenceFace,
  });

  @override
  State<FaceMatchingPage> createState() => _FaceMatchingPageState();
}

class _FaceMatchingPageState extends State<FaceMatchingPage> with SingleTickerProviderStateMixin {
  CameraController? _controller;
  bool _isProcessing = false;
  String _status = 'Positionnez votre visage dans le cadre';
  String? _videoPath;
  Uint8List? _videoFrame;
  Map<String, dynamic>? _matchResult;
  LivenessResult? _liveness;
  int _countdown = 0;
  late AnimationController _animationController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _animationController = AnimationController(
      duration: const Duration(seconds: 1),
      vsync: this,
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(
      begin: 1.0,
      end: 1.1,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
  }

  Future<void> _initializeCamera() async {
    if (widget.cameras.isNotEmpty) {
      // Find front camera or use first available
      CameraDescription camera = widget.cameras.first;
      for (var cam in widget.cameras) {
        if (cam.lensDirection == CameraLensDirection.front) {
          camera = cam;
          break;
        }
      }

      _controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      try {
        await _controller!.initialize();
        setState(() {});
      } catch (e) {
        setState(() {
          _status = '❌ Erreur d\'initialisation de la caméra: $e';
        });
      }
    }
  }

  Future<void> _startVerification() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    setState(() {
      _isProcessing = true;
      _status = '🎥 Enregistrement en cours...';
      _matchResult = null;
      _videoFrame = null;
      _countdown = 3;
    });

    try {
      // Countdown
      for (int i = 3; i > 0; i--) {
        setState(() => _countdown = i);
        await Future.delayed(const Duration(seconds: 1));
      }

      setState(() {
        _countdown = 0;
        _status = '🎬 Enregistrement... Regardez la caméra';
      });

      // Start recording
      await _controller!.startVideoRecording();

      // Record for 3 seconds
      await Future.delayed(const Duration(seconds: 3));

      // Stop recording
      final video = await _controller!.stopVideoRecording();
      _videoPath = video.path;

      setState(() {
        _status = '📸 Extraction d\'une image de la vidéo...';
      });

      // Extract a frame from video for display
      await _extractVideoFrame();

      setState(() {
        _status = '🔄 Comparaison biométrique en cours...';
      });

      // Perform face matching
      await _performFaceMatching();

    } catch (e) {
      setState(() {
        _status = '❌ Erreur lors de la vérification: $e';
        _isProcessing = false;
        _countdown = 0;
      });
    }
  }

  Future<void> _extractVideoFrame() async {
    if (_videoPath == null) return;

    try {
      // Take a screenshot from camera preview as fallback
      final image = await _controller!.takePicture();
      final bytes = await File(image.path).readAsBytes();
      setState(() {
        _videoFrame = bytes;
      });
    } catch (e) {
      print('Erreur lors de l\'extraction de l\'image: $e');
    }
  }

  Future<void> _performFaceMatching() async {
    if (_videoPath == null) return;

    try {
      // Liveness goes through the Cortixia portal proxy: authenticated with
      // the client's API token and metered against their quota.
      final host = KycFlowHost.of(context);
      final Map<String, dynamic> result = await host.backend.liveness(
        faceBytes: widget.referenceFace,
        videoPath: _videoPath!,
        sessionId: host.sessionId,
      );

      {
        // Parse new response format
        bool isMatch = result['decision'] == 'True';
        Map<String, dynamic>? details = result['details'];
        double spoofRatio = (details?['spoof_ratio'] ?? 0.0).toDouble();
        bool isSpoofed = spoofRatio > 0;

        _liveness = LivenessResult(
          isMatch: isMatch,
          isSpoof: isSpoofed,
          spoofRatio: spoofRatio,
          raw: result,
        );

        if (isMatch && !isSpoofed) {
          // Verification passed — finish the whole flow with a success result.
          if (mounted) {
            KycFlowHost.of(context).completeSuccess(liveness: _liveness);
          }
        }

        // Add spoofed flag to result for UI compatibility
        result['spoofed'] = isSpoofed;

        setState(() {
          _matchResult = result;
          _isProcessing = false;

          if (isSpoofed) {
            _status = '⚠️ Tentative de fraude détectée';
          } else if (isMatch) {
            _status = '✅ Identité vérifiée avec succès!';
          } else {
            _status = '❌ Aucune correspondance trouvée';
          }
        });
      }
    } on KycLicenseException catch (e) {
      // Token rejected or quota exhausted — the flow cannot continue.
      if (mounted) {
        setState(() {
          _status = '❌ ${e.message}';
          _isProcessing = false;
        });
        KycFlowHost.of(context).completeFailed(e);
      }
    } catch (e) {
      setState(() {
        _status = '❌ Erreur lors de la comparaison: $e';
        _isProcessing = false;
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFFFFF),
      appBar: AppBar(
        title: const Text('Vérification biométrique'),
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
            children: [
              // Status card
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _getStatusColor().withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _getStatusColor()),
                ),
                child: Row(
                  children: [
                    Icon(_getStatusIcon(), color: _getStatusColor()),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _status,
                        style: TextStyle(
                          fontSize: 14,
                          color: _getStatusColor(),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              if (_matchResult == null) ...[
                // Camera preview when not showing results
                if (_controller?.value.isInitialized == true) ...[
                  Expanded(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.2),
                                blurRadius: 10,
                                offset: const Offset(0, 5),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: CameraPreview(_controller!),
                          ),
                        ),

                        // Face outline guide
                        CustomPaint(
                          size: const Size(300, 400),
                          painter: FaceGuidePainter(),
                        ),

                        // Countdown overlay
                        if (_countdown > 0)
                          AnimatedBuilder(
                            animation: _pulseAnimation,
                            builder: (context, child) {
                              return Transform.scale(
                                scale: _pulseAnimation.value,
                                child: Container(
                                  width: 100,
                                  height: 100,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.9),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Center(
                                    child: Text(
                                      '$_countdown',
                                      style: const TextStyle(
                                        fontSize: 48,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF1E3A5F),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ] else ...[
                  const Expanded(
                    child: Center(
                      child: CircularProgressIndicator(color: Color(0xFF1E3A5F)),
                    ),
                  ),
                ],

                const SizedBox(height: 12),

                // Instructions card (Flexible so it shrinks on small screens)
                Flexible(
                  flex: 0,
                  child: Card(
                    color: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            '📋 Instructions',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF111827),
                            ),
                          ),
                          const SizedBox(height: 8),
                          _buildInstruction('1️⃣', 'Placez votre visage dans le cadre'),
                          _buildInstruction('2️⃣', 'Assurez-vous d\'être bien éclairé'),
                          _buildInstruction('3️⃣', 'Regardez directement la caméra'),
                          _buildInstruction('4️⃣', 'Restez immobile pendant l\'enregistrement'),
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Verification button
                Container(
                  width: double.infinity,
                  height: 50,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1E3A5F), Color(0xFF0D9488)],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF1E3A5F).withOpacity(0.2),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _startVerification,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    icon: _isProcessing
                        ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                        : const Icon(Icons.face_retouching_natural, color: Colors.white),
                    label: Text(
                      _isProcessing ? 'Vérification en cours...' : 'Commencer la vérification',
                      style: const TextStyle(fontSize: 16, color: Colors.white),
                    ),
                  ),
                ),
              ] else ...[
                // Results view
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                    children: [
                      // Result status card
                      Card(
                        color: _getResultColor(),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Icon(
                                _getResultIcon(),
                                color: Colors.white,
                                size: 32,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _getResultTitle(),
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    if (_matchResult!['spoofed'] == true || _matchResult!['spoofed'] == 'True') ...[
                                      const SizedBox(height: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: const Text(
                                          '🚫 Tentative de fraude détectée',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Images comparison
                      const Text(
                        'Comparaison des images',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 8),

                      SizedBox(
                        height: 200,
                        child: Row(
                          children: [
                            // ID card image
                            Expanded(
                              child: Column(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1E3A5F).withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: const Text(
                                      '🆔 Carte d\'identité',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF1E3A5F),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        border: Border.all(color: const Color(0xFF1E3A5F).withOpacity(0.2)),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child: Image.memory(
                                          widget.referenceFace,
                                          fit: BoxFit.contain,
                                          width: double.infinity,
                                          errorBuilder: (context, error, stackTrace) {
                                            return const Center(
                                              child: Text(
                                                'Image non disponible',
                                                style: TextStyle(color: Colors.white54),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(width: 16),

                            // Video frame
                            Expanded(
                              child: Column(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0D9488).withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: const Text(
                                      '📸 Photo prise',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF0D9488),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        border: Border.all(color: const Color(0xFF0D9488).withOpacity(0.2)),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child: _videoFrame != null
                                            ? Image.memory(
                                          _videoFrame!,
                                          fit: BoxFit.contain,
                                          width: double.infinity,
                                        )
                                            : const Center(
                                          child: Text(
                                            'Image non disponible',
                                            style: TextStyle(color: Colors.white54),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Action buttons
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFF1E3A5F), Color(0xFF163050)],
                                ),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  setState(() {
                                    _matchResult = null;
                                    _videoFrame = null;
                                    _status = 'Positionnez votre visage dans le cadre';
                                  });
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                                icon: const Icon(Icons.refresh, color: Colors.white),
                                label: const Text(
                                  'Réessayer',
                                  style: TextStyle(fontSize: 16, color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFF0D9488), Color(0xFF0F766E)],
                                ),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  final liveness = _liveness;
                                  KycFlowHost.of(context).completeFailed(
                                    liveness != null && liveness.isSpoof
                                        ? const KycLivenessException(
                                            KycLivenessError.spoofDetected,
                                            'Tentative de fraude détectée')
                                        : const KycLivenessException(
                                            KycLivenessError.noMatch,
                                            'Aucune correspondance trouvée'),
                                    liveness: liveness,
                                  );
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                                icon: const Icon(Icons.check, color: Colors.white),
                                label: const Text(
                                  'Terminer',
                                  style: TextStyle(fontSize: 16, color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInstruction(String number, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(number, style: const TextStyle(fontSize: 16, color: Color(0xFF111827))),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: Color(0xFF374151)),
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor() {
    if (_isProcessing) return const Color(0xFF1E3A5F);
    if (_matchResult != null) {
      bool isSpoofed = _matchResult!['spoofed'] == true || _matchResult!['spoofed'] == 'True';
      bool isMatch = _matchResult!['decision'] == true || _matchResult!['decision'] == 'True';
      if (isSpoofed) return Colors.orange;
      return isMatch ? const Color(0xFF0D9488) : const Color(0xFFFF6B6B);
    }
    return const Color(0xFF6B7280);
  }

  IconData _getStatusIcon() {
    if (_isProcessing) return Icons.hourglass_empty;
    if (_matchResult != null) {
      bool isSpoofed = _matchResult!['spoofed'] == true || _matchResult!['spoofed'] == 'True';
      bool isMatch = _matchResult!['decision'] == true || _matchResult!['decision'] == 'True';
      if (isSpoofed) return Icons.warning;
      return isMatch ? Icons.check_circle : Icons.cancel;
    }
    return Icons.info_outline;
  }

  Color _getResultColor() {
    if (_matchResult == null) return Colors.grey;

    bool isSpoofed = _matchResult!['spoofed'] == true || _matchResult!['spoofed'] == 'True';
    bool isMatch = _matchResult!['decision'] == true || _matchResult!['decision'] == 'True';

    if (isSpoofed) return Colors.orange;
    return isMatch ? const Color(0xFF0D9488) : const Color(0xFFFF6B6B);
  }

  IconData _getResultIcon() {
    if (_matchResult == null) return Icons.help;

    bool isSpoofed = _matchResult!['spoofed'] == true || _matchResult!['spoofed'] == 'True';
    bool isMatch = _matchResult!['decision'] == true || _matchResult!['decision'] == 'True';

    if (isSpoofed) return Icons.warning;
    return isMatch ? Icons.check_circle : Icons.cancel;
  }

  String _getResultTitle() {
    if (_matchResult == null) return '';

    bool isSpoofed = _matchResult!['spoofed'] == true || _matchResult!['spoofed'] == 'True';
    bool isMatch = _matchResult!['decision'] == true || _matchResult!['decision'] == 'True';

    if (isSpoofed) return 'Fraude détectée';
    return isMatch ? 'Correspondance confirmée' : 'Aucune correspondance';
  }
}

class FaceGuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    // Draw oval for face guide
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCenter(
      center: center,
      width: size.width * 0.7,
      height: size.height * 0.5,
    );

    canvas.drawOval(rect, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}