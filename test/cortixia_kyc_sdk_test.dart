import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cortixia_kyc_sdk/cortixia_kyc_sdk.dart';

void main() {
  testWidgets('scans require initialize() first', (tester) async {
    expect(CortixiaKyc.isInitialized, isFalse);

    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctx = context;
        return const SizedBox.shrink();
      }),
    ));

    expect(
      () => CortixiaKyc.scanIdCard(ctx),
      throwsA(isA<KycNotInitializedException>()),
    );
  });

  test('document types map to the wire values used by the API', () {
    expect(KycDocumentType.idCard.wire, 'idcard');
    expect(KycDocumentType.passport.wire, 'passport');
    expect(KycDocumentType.drivingLicence.wire, 'drivinglicence');
  });

  test('cancelled results carry no document', () {
    const result = KycResult.cancelled(KycDocumentType.passport);
    expect(result.status, KycStatus.cancelled);
    expect(result.document, isNull);
    expect(result.liveness, isNull);
  });

  test('DocumentDataMapper maps ID card datagroups to the stable shape', () {
    final data = DocumentDataMapper.map(
      KycDocumentType.idCard,
      {
        'dg11': {
          'result': 'True',
          'name_latin': 'MOHAMED',
          'surname_latin': 'ZIDOUN',
          'birth_date': '1995/03/12',
          'nin': '109950302004330006',
        },
        'dg12': {'result': 'True', 'daira': 'ALGER', 'baladia_latin': 'BAB EZZOUAR'},
        'dg2': {'result': 'True', 'face': 'AAAA'},
      },
      mrzDocumentNumber: '123456789',
    );

    expect(data.personal['firstName'], 'MOHAMED');
    expect(data.personal['lastName'], 'ZIDOUN');
    expect(data.personal['nin'], '109950302004330006');
    expect(data.document['idNumber'], '123456789');
    expect(data.document['daira'], 'ALGER');
    expect(data.biometric['faceImage'], 'AAAA');
    expect(data.toJson()['documentType'], 'idcard');
  });

  test('DocumentDataMapper maps driving licence categories and Arabic fields', () {
    final data = DocumentDataMapper.map(
      KycDocumentType.drivingLicence,
      {
        'dg1': {
          'result': 'True',
          'name_latin': 'MOHAMED',
          'surname_latin': 'ZIDOUN',
          'licence_number': 'DL123',
          'categories': 'A (2025-10-13 → 2035-10-12)',
        },
        'dg12': {'result': 'True', 'nin': '109950302004330006'},
        'dg13': {'result': 'True', 'surname_arabic': 'زيدون', 'blood_type': 'O+'},
        'dg5': {'result': 'True', 'face': 'BBBB'},
      },
    );

    expect(data.document['licenceNumber'], 'DL123');
    expect(data.document['categories'], 'A (2025-10-13 → 2035-10-12)');
    expect(data.personal['lastNameAr'], 'زيدون');
    expect(data.personal['bloodType'], 'O+');
    expect(data.biometric['faceImage'], 'BBBB');
  });
}
