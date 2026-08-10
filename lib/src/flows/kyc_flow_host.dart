import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../backend/sdk_backend_client.dart';
import '../cortixia_kyc.dart';
import '../models/document_data_mapper.dart';
import '../models/kyc_models.dart';
import 'driving_licence/driving_licence_mrz_scanner_page.dart';
import 'driving_licence/driving_licence_read_nfc_page.dart';
import 'idcard/mrz_scanner_page.dart';
import 'idcard/read_nfc_page.dart';
import 'liveness/face_matching_page.dart';
import 'passport/passport_mrz_scanner_page.dart';
import 'passport/passport_read_nfc_page.dart';

/// Which portion of the flow to run.
enum KycFlowMode {
  /// MRZ → NFC → liveness (the classic scanX entry points).
  full,

  /// Read the MRZ and stop.
  mrzOnly,

  /// Skip the camera: go straight to the chip using supplied BAC keys.
  nfcOnly,

  /// Skip document capture entirely: liveness against a supplied face.
  livenessOnly,
}

/// Hosts one KYC flow (MRZ → NFC → liveness) inside a nested [Navigator].
///
/// The host occupies exactly ONE route on the app's navigator; internal pages
/// push/pop only within the nested navigator, and the flow finishes by popping
/// the host route with a [KycResult]. Android back pops internal pages first
/// and cancels the flow from the first page.
class KycFlowHost extends StatefulWidget {
  final KycDocumentType documentType;
  final KycScanOptions options;
  final CortixiaKycConfig config;

  /// Which portion of the flow to run. One host drives every entry point so
  /// session id, camera bootstrap, back handling and metering stay in one place.
  final KycFlowMode mode;

  /// Required by [KycFlowMode.nfcOnly].
  final BacKeys? bacKeys;

  /// Required by [KycFlowMode.livenessOnly].
  final Uint8List? referenceFace;

  final MrzScanOptions? mrzOptions;

  const KycFlowHost({
    super.key,
    required this.documentType,
    required this.options,
    required this.config,
    this.mode = KycFlowMode.full,
    this.bacKeys,
    this.referenceFace,
    this.mrzOptions,
  });

  static KycFlowHostState of(BuildContext context) {
    // getInherited... (not dependOn...) so pages can call this from async
    // event handlers, not only during build.
    final scope = context.getInheritedWidgetOfExactType<_KycFlowScope>();
    assert(scope != null, 'KycFlowHost.of() called outside a KYC flow');
    return scope!.host;
  }

  @override
  State<KycFlowHost> createState() => KycFlowHostState();
}

class KycFlowHostState extends State<KycFlowHost> {
  final _navKey = GlobalKey<NavigatorState>();
  late final Future<List<CameraDescription>> _camerasFuture = availableCameras();
  late final String sessionId = SdkBackendClient.newSessionId();

  KycDocumentData? _document;
  MrzResult? _mrz;
  bool _completed = false;

  KycScanOptions get options => widget.options;
  CortixiaKycConfig get config => widget.config;
  KycDocumentType get documentType => widget.documentType;
  KycFlowMode get mode => widget.mode;

  /// Set by the MRZ page; also the result of a [KycFlowMode.mrzOnly] flow.
  MrzResult? get mrz => _mrz;
  set mrz(MrzResult? value) => _mrz = value;

  /// True when the chip read should follow the MRZ step.
  bool get continuesToChip => widget.mode == KycFlowMode.full;
  SdkBackendClient get backend => CortixiaKyc.backend;

  @override
  void initState() {
    super.initState();
    // Metering: telemetry-only event, fire-and-forget.
    backend.postEvent(
      eventType: 'scan_started',
      documentType: widget.documentType.wire,
      sessionId: sessionId,
    );
  }

  /// Called by NFC pages after a successful decode. Maps the raw datagroup
  /// output, stores it as the flow's document, and asks the host app (via
  /// [KycScanOptions.onDocumentRead]) how to proceed.
  Future<KycFlowDecision> documentRead(
    Map<String, dynamic> raw, {
    required String mrzDocumentNumber,
    required String mrzBirthDate,
    required String mrzExpiryDate,
  }) async {
    _document = DocumentDataMapper.map(
      widget.documentType,
      raw,
      mrzDocumentNumber: mrzDocumentNumber,
      mrzBirthDate: mrzBirthDate,
      mrzExpiryDate: mrzExpiryDate,
    );
    final hook = widget.options.onDocumentRead;
    var decision =
        hook != null ? await hook(_document!) : KycFlowDecision.continueToLiveness;
    if (decision == KycFlowDecision.continueToLiveness &&
        !widget.options.withLiveness) {
      decision = KycFlowDecision.completeWithoutLiveness;
    }
    return decision;
  }

  KycDocumentData? get document => _document;

  void completeSuccess({LivenessResult? liveness}) => _finish(KycResult(
        documentType: widget.documentType,
        status: KycStatus.success,
        document: _document,
        liveness: liveness,
        mrz: _mrz,
      ));

  void completeFailed(KycException error, {LivenessResult? liveness}) =>
      _finish(KycResult(
        documentType: widget.documentType,
        status: KycStatus.failed,
        document: _document,
        liveness: liveness,
        error: error,
        mrz: _mrz,
      ));

  void cancel() => _finish(KycResult.cancelled(widget.documentType));

  void _finish(KycResult result) {
    if (_completed || !mounted) return;
    _completed = true;
    // Metering: scan_completed counts against the quota only when the chip
    // was actually read (a cancel before decode is free telemetry-wise —
    // no scan_completed is emitted at all in that case).
    if (result.document != null) {
      backend.postEvent(
        eventType: 'scan_completed',
        documentType: widget.documentType.wire,
        sessionId: sessionId,
        success: result.status == KycStatus.success,
        errorCode: result.error is KycException ? '${result.error.runtimeType}' : '',
      );
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final nav = _navKey.currentState;
        if (nav != null && nav.canPop()) {
          nav.pop();
        } else {
          cancel();
        }
      },
      child: FutureBuilder<List<CameraDescription>>(
        future: _camerasFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              completeFailed(KycCameraException('${snapshot.error}'));
            });
            return const Scaffold(body: SizedBox.shrink());
          }
          if (!snapshot.hasData) {
            return const Scaffold(
              backgroundColor: Color(0xFFFFFFFF),
              body: Center(child: CircularProgressIndicator(color: Color(0xFF1E3A5F))),
            );
          }
          final cameras = snapshot.data!;
          return _KycFlowScope(
            host: this,
            child: Navigator(
              key: _navKey,
              onGenerateInitialRoutes: (nav, initialRoute) => [
                MaterialPageRoute(builder: (_) => _firstPage(cameras)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _firstPage(List<CameraDescription> cameras) {
    switch (widget.mode) {
      case KycFlowMode.livenessOnly:
        return FaceMatchingPage(
          cameras: cameras,
          referenceFace: widget.referenceFace!,
        );
      case KycFlowMode.nfcOnly:
        final keys = widget.bacKeys!;
        return _nfcPage(cameras, keys);
      case KycFlowMode.full:
      case KycFlowMode.mrzOnly:
        return switch (widget.documentType) {
          KycDocumentType.idCard => MrzScannerPage(cameras: cameras),
          KycDocumentType.passport => PassportMrzScannerPage(cameras: cameras),
          KycDocumentType.drivingLicence =>
            DrivingLicenceMrzScannerPage(cameras: cameras),
        };
    }
  }

  /// The NFC pages take ISO dates; BAC keys carry the raw MRZ YYMMDD form.
  static String _isoFromMrzDate(String yymmdd, {required bool isBirth}) {
    if (yymmdd.length != 6) return yymmdd;
    final yy = int.tryParse(yymmdd.substring(0, 2)) ?? 0;
    final year = isBirth ? (yy < 30 ? 2000 + yy : 1900 + yy) : 2000 + yy;
    return '$year-${yymmdd.substring(2, 4)}-${yymmdd.substring(4, 6)}';
  }

  Widget _nfcPage(List<CameraDescription> cameras, BacKeys keys) {
    final dob = _isoFromMrzDate(keys.birthDate, isBirth: true);
    final doe = _isoFromMrzDate(keys.expiryDate, isBirth: false);
    return switch (widget.documentType) {
      KycDocumentType.idCard => ReadNfcPage(
          cameras: cameras, idNumber: keys.documentNumber, dob: dob, doe: doe),
      KycDocumentType.passport => PassportReadNfcPage(
          cameras: cameras, passportNumber: keys.documentNumber, dob: dob, doe: doe),
      KycDocumentType.drivingLicence => DrivingLicenceReadNfcPage(
          cameras: cameras, licenceNumber: keys.documentNumber, dob: dob, doe: doe),
    };
  }
}

class _KycFlowScope extends InheritedWidget {
  final KycFlowHostState host;
  const _KycFlowScope({required this.host, required super.child});

  @override
  bool updateShouldNotify(_KycFlowScope oldWidget) => host != oldWidget.host;
}
