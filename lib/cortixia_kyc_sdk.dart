/// Cortixia KYC SDK — Algerian eKYC document scanning for Flutter.
///
/// ```dart
/// await CortixiaKyc.initialize(CortixiaKycConfig(apiToken: 'ck_live_...'));
/// final result = await CortixiaKyc.scanIdCard(context);
/// ```
library;

export 'src/cortixia_kyc.dart';
export 'src/models/kyc_models.dart';
export 'src/models/document_data_mapper.dart';
export 'src/backend/sdk_backend_client.dart' show KycLicenseInfo;
export 'src/flows/kyc_flow_host.dart' show KycFlowMode;
