import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cortixia_kyc_sdk/cortixia_kyc_sdk.dart';
import 'package:cortixia_kyc_sdk/src/backend/sdk_backend_client.dart';
import 'package:cortixia_kyc_sdk/src/flows/mrz_prefilter.dart';

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

  test('reported sdkVersion matches pubspec', () {
    // This drifted once already: the client reported 0.1.0 for two releases,
    // so every metered row recorded the wrong version.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*(\S+)', multiLine: true)
        .firstMatch(pubspec)!
        .group(1);
    expect(SdkBackendClient.sdkVersion, version);
  });

  test('MrzResult exposes both the ISO dates and the raw BAC keys', () {
    final mrz = MrzResult.fromJson(KycDocumentType.idCard, {
      'fields': {
        'document_number': '123456789',
        'birth_date': '1995-03-12',
        'expiry_date': '2036-04-22',
        'surname': 'ZIDOUN',
        'given_names': 'MOHAMED',
      },
      'mrz_keys': {'birth_date': '950312', 'expiry_date': '360422'},
    });
    expect(mrz.documentNumber, '123456789');
    expect(mrz.birthDate, '1995-03-12');
    expect(mrz.birthDateMrz, '950312');
    expect(mrz.expiryDateMrz, '360422');
    expect(mrz.surname, 'ZIDOUN');
  });

  group('MRZ glyph normalisation', () {
    // ML Kit renders the MRZ filler as a French guillemet on some documents.
    // Reported from a real Xiaomi scan: "caractère invalide dans la MRZ : '«'".
    final idCard = MrzPrefilter(KycDocumentType.idCard);

    test('« expands to << when that lands the line on 30 characters', () {
      // Built arithmetically rather than counted by hand: 28 real characters
      // plus a « standing in for a << pair is 30 once expanded.
      final line = '${'A' * 28}«';
      final out = idCard.normaliseLines([line]);
      expect(out.single.length, 30);
      expect(out.single.endsWith('<<'), isTrue);
      expect(out.single.contains('«'), isFalse);
    });

    test('« collapses to < when THAT is what fits', () {
      // 29 real characters plus a « standing in for a single < is already 30.
      final line = '${'A' * 29}«';
      final out = idCard.normaliseLines([line]);
      expect(out.single.length, 30,
          reason: 'expanding to << would overshoot to 31 and shift every '
              'fixed-position field after it');
      expect(out.single.endsWith('A<'), isTrue);
    });

    test('single-width glyphs map to < unconditionally', () {
      final out = idCard.normaliseLines(['IDDZA\u2039\uFF1C\u3008']);
      expect(out.single, 'IDDZA<<<');
    });

    test('passport lines disambiguate against 44, not 30', () {
      final passport = MrzPrefilter(KycDocumentType.passport);
      final line = '${'A' * 42}«';  // 42 real chars + « -> 44
      final out = passport.normaliseLines([line]);
      expect(out.single.length, 44);
      expect(out.single.endsWith('<<'), isTrue);
    });

    test('content characters are never guessed at', () {
      // O/0 and S/5 confusions are content, not glyph artifacts: correcting
      // them could turn an invalid MRZ into a valid-looking wrong one.
      final out = idCard.normaliseLines(['IDDZAO12S4567897109950302004330']);
      expect(out.single.contains('O'), isTrue);
      expect(out.single.contains('S'), isTrue);
    });

    test('whitespace is stripped and case normalised', () {
      final out = idCard.normaliseLines([' iddza 123 ']);
      expect(out.single, 'IDDZA123');
    });
  });

  test('MRZ pre-filter needs two consecutive identical frames', () {
    final f = MrzPrefilter(KycDocumentType.idCard);
    final lines = [
      'IDDZA1234567897109950302004330',
      '9503127M3604225DZA<<<<<<<<<<<4',
      'ZIDOUN<<MOHAMED<<<<<<<<<<<<<<<',
    ];
    expect(f.offer(lines), isNull, reason: 'first sighting waits');
    expect(f.offer(lines), isNotNull, reason: 'confirmed on the second');
    expect(f.offer(lines), isNull, reason: 'same lines are not sent twice');
    expect(f.offer(['not', 'an', 'mrz']), isNull);
  });
}
