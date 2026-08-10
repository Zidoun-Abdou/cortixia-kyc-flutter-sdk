import 'kyc_models.dart';

/// Maps the decoders' raw per-datagroup output into the stable
/// personal/document/biometric shape of [KycDocumentData].
///
/// The field mappings mirror the historical Cortixia app services
/// (IDCardService/PassportService/DrivingLicenceService.saveNFCData) so that
/// data returned by the SDK is drop-in compatible with existing consumers.
class DocumentDataMapper {
  static KycDocumentData map(
    KycDocumentType type,
    Map<String, dynamic> raw, {
    String mrzDocumentNumber = '',
    String mrzBirthDate = '',
    String mrzExpiryDate = '',
  }) {
    final personal = <String, dynamic>{};
    final document = <String, dynamic>{};
    final biometric = <String, String>{};

    switch (type) {
      case KycDocumentType.idCard:
        final dg11 = raw['dg11'] as Map<String, dynamic>?;
        if (dg11 != null) {
          personal['firstName'] = dg11['name_latin'] ?? '';
          personal['firstNameAr'] = dg11['name_arabic'] ?? '';
          personal['lastName'] = dg11['surname_latin'] ?? '';
          personal['lastNameAr'] = dg11['surname_arabic'] ?? '';
          personal['birthDate'] = dg11['birth_date'] ?? '';
          personal['birthPlace'] = dg11['birthplace_latin'] ?? '';
          personal['birthPlaceAr'] = dg11['birthplace_arabic'] ?? '';
          personal['sex'] = dg11['sex_latin'] ?? '';
          personal['bloodType'] = dg11['blood_type'] ?? '';
          personal['nin'] = dg11['nin'] ?? '';
        }
        final dg12 = raw['dg12'] as Map<String, dynamic>?;
        if (dg12 != null) {
          document['idNumber'] = mrzDocumentNumber;
          document['daira'] = dg12['daira'] ?? '';
          document['baladia'] = dg12['baladia_latin'] ?? '';
          document['baladiaAr'] = dg12['baladia_arabic'] ?? '';
          document['issueDate'] = dg12['delivery_date'] ?? '';
          document['expiryDate'] = dg12['expiry_date'] ?? '';
        }
        _face(biometric, raw['dg2']);
        _signature(biometric, raw['dg7']);

      case KycDocumentType.passport:
        final dg11 = raw['dg11'] as Map<String, dynamic>?;
        if (dg11 != null) {
          personal['firstName'] = dg11['name_latin'] ?? '';
          personal['lastName'] = dg11['surname_latin'] ?? '';
          personal['birthDate'] = dg11['birth_date'] ?? '';
          personal['birthPlace'] = dg11['birthplace_latin'] ?? '';
          personal['bloodType'] = dg11['blood_type'] ?? '';
          personal['nin'] = dg11['nin'] ?? '';
        }
        final dg12 = raw['dg12'] as Map<String, dynamic>?;
        if (dg12 != null) {
          document['passportNumber'] = mrzDocumentNumber;
          document['commune'] = dg12['commune_latin'] ?? '';
          document['creationDate'] = dg12['creation_date'] ?? '';
        }
        _face(biometric, raw['dg2']);
        _signature(biometric, raw['dg7']);

      case KycDocumentType.drivingLicence:
        final dg1 = raw['dg1'] as Map<String, dynamic>?;
        if (dg1 != null) {
          personal['firstName'] = dg1['name_latin'] ?? '';
          personal['lastName'] = dg1['surname_latin'] ?? '';
          personal['birthDate'] = dg1['birth_date'] ?? '';
          document['licenceNumber'] = dg1['licence_number'] ?? '';
          document['commune'] = dg1['commune_latin'] ?? '';
          document['issueDate'] = dg1['issue_date'] ?? '';
          document['expiryDate'] = dg1['expiry_date'] ?? '';
          document['categories'] = dg1['categories'] ?? '';
        }
        final dg11 = raw['dg11'] as Map<String, dynamic>?;
        if (dg11 != null) {
          if (dg11['sex_latin'] != null) personal['sex'] = dg11['sex_latin'];
          if (dg11['birthplace_latin'] != null) {
            personal['birthPlace'] = dg11['birthplace_latin'];
          }
        }
        final dg12 = raw['dg12'] as Map<String, dynamic>?;
        if (dg12 != null && (dg12['nin'] as String? ?? '').isNotEmpty) {
          personal['nin'] = dg12['nin'];
        }
        final dg13 = raw['dg13'] as Map<String, dynamic>?;
        if (dg13 != null) {
          personal['firstNameAr'] = dg13['name_arabic'] ?? '';
          personal['lastNameAr'] = dg13['surname_arabic'] ?? '';
          if ((dg13['blood_type'] as String? ?? '').isNotEmpty) {
            personal['bloodType'] = dg13['blood_type'];
          }
          if ((dg13['place_arabic'] as String? ?? '').isNotEmpty) {
            document['communeAr'] = dg13['place_arabic'];
          }
        }
        _face(biometric, raw['dg5'] ?? raw['dg2']);
        _signature(biometric, raw['dg7']);
    }

    return KycDocumentData(
      documentType: type,
      personal: personal,
      document: document,
      biometric: biometric,
      rawDecoded: raw,
      mrzDocumentNumber: mrzDocumentNumber,
      mrzBirthDate: mrzBirthDate,
      mrzExpiryDate: mrzExpiryDate,
    );
  }

  static void _face(Map<String, String> biometric, dynamic dg) {
    final face = (dg as Map<String, dynamic>?)?['face'] as String? ?? '';
    if (face.isNotEmpty) biometric['faceImage'] = face;
  }

  static void _signature(Map<String, String> biometric, dynamic dg) {
    final sig = (dg as Map<String, dynamic>?)?['signature'] as String? ?? '';
    if (sig.isNotEmpty) biometric['signature'] = sig;
  }
}
