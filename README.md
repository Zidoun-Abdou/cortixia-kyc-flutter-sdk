# Cortixia KYC SDK (Flutter)

Algerian eKYC for your Flutter app: scan the **biometric ID card**, **passport**
or **driving licence** (MRZ camera scan → NFC chip read → secure decoding) and
run **face-matching/liveness** — gated by a Cortixia API token.

Get a token: create an account at **https://www.e-kyc.online/portal/signup/**
(50 free trial scans), then follow the integration guide at
`https://www.e-kyc.online/portal/docs/` (shows snippets with your real token).

## Installation

```yaml
dependencies:
  cortixia_kyc_sdk:
    git:
      url: https://github.com/Zidoun-Abdou/cortixia-kyc-flutter-sdk.git
      ref: v0.4.0
```

## Android requirements

- Set `minSdk = 26` in `android/app/build.gradle.kts` (replace
  `flutter.minSdkVersion`), and use a device with NFC
- Permissions in `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.NFC" />
```

That's it — the SDK ships no native code of its own, so there are no extra
Maven repositories or platform registrants to configure.

### Release build (R8 / ProGuard)

The SDK reads the MRZ with ML Kit, which references optional per-language
recognizers (Chinese, Devanagari, Japanese, Korean) it does not bundle. A
release build fails at `minifyReleaseWithR8` until those are suppressed. Add to
`android/app/proguard-rules.pro`:

```proguard
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
```

and reference it in the `release` build type:

```kotlin
isMinifyEnabled = true
isShrinkResources = true
proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
```

## iOS

Supported for the **ID card and passport** flows (device-verified). Your host
app needs, in `ios/`:

1. **A paid Apple Developer team** — the NFC entitlement is not available to
   free/Personal teams.
2. `Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>La caméra est utilisée pour scanner votre document et vérifier votre identité.</string>
<key>NFCReaderUsageDescription</key>
<string>Le lecteur NFC lit la puce de votre document d'identité.</string>
<key>com.apple.developer.nfc.readersession.iso7816.select-identifiers</key>
<array>
  <string>A0000002471001</string>
</array>
```

3. A `Runner/Runner.entitlements` wired into the target (Xcode: Signing &
   Capabilities → + Capability → **Near Field Communication Tag Reading**, or
   by hand):

```xml
<key>com.apple.developer.nfc.readersession.formats</key>
<array><string>TAG</string></array>
```

4. `Podfile`: `platform :ios, '15.5'` (required by `google_mlkit_*`).

iOS UX notes: the system "Ready to Scan" sheet handles the NFC prompt, and the
iPhone's NFC antenna is at the **top** back edge (unlike Android's mid-back).
The **driving-licence** flow remains Android-only (its IDL applet id
`A0000002480200` would need adding to the select-identifiers list; untested).

## Quick start

```dart
import 'package:cortixia_kyc_sdk/cortixia_kyc_sdk.dart';

// 1. Initialize once (validates your token online; throws KycLicenseException
//    on an invalid/expired token or exhausted quota; grace mode when offline).
final license = await CortixiaKyc.initialize(CortixiaKycConfig(
  apiToken: 'ck_live_...',   // from https://www.e-kyc.online/portal/
));

// 2. Launch a scan — the SDK shows its own UI (MRZ camera → NFC → liveness)
//    and returns when the flow finishes.
final KycResult result = await CortixiaKyc.scanIdCard(context);
// also: scanPassport(context) / scanDrivingLicence(context)

switch (result.status) {
  case KycStatus.success:
    final data = result.document!;        // decoded identity
    print(data.personal['firstName']);    // + lastName(+Ar), birthDate, nin, ...
    print(data.document);                 // document numbers, dates, categories
    final faceJpegB64 = data.biometric['faceImage'];
    final liveness = result.liveness;     // null if skipped
  case KycStatus.cancelled: break;        // user backed out / host aborted
  case KycStatus.failed:
    print(result.error);                  // KycLivenessException / KycNfcException / ...
}
```

### Options

```dart
CortixiaKyc.scanIdCard(context, options: KycScanOptions(
  withLiveness: true,            // false → return right after the chip read
  includeRawDataGroups: false,
  onDocumentRead: (data) async { // hook between chip read and liveness
    // e.g. check data.personal['nin'] against your own backend:
    return KycFlowDecision.continueToLiveness;
    //     | KycFlowDecision.completeWithoutLiveness
    //     | KycFlowDecision.abort
  },
));
```

### Errors

`KycLicenseException` (invalidToken / licenseExpired / quotaExceeded /
networkUnreachable) · `KycNfcException` · `KycCameraException` ·
`KycLivenessException` (noMatch / spoofDetected / serverError / networkError) ·
`KycNotInitializedException`.

### Your API token is not a secret

The token ships inside your application binary, so anyone with your APK can
extract it — this is true of every mobile SDK. It identifies your account
rather than proving the caller is trustworthy. Your protection is the quota
(which caps what any misuse can cost) and instant rotation: regenerate the
token from your dashboard and the old one stops working immediately.

### Licensing & metering

`initialize` validates your token against the Cortixia portal. Datagroup
decoding then runs server-side: **one successful document decode consumes one
credit**, and that is the only billable operation — telemetry events and the
liveness check are free. When your quota is exhausted the server answers 402
and the SDK raises `KycLicenseError.quotaExceeded`; top up from your dashboard
at https://www.e-kyc.online/portal/.

Decoded identity data is returned to your app and is **not stored** by
Cortixia. Chip bytes are processed in memory for the duration of the call.

## Status / roadmap

| Phase | Content | State |
|---|---|---|
| v0.1 | MRZ + NFC reading, full flow UI, `KycResult`, token licensing and usage metering | ✅ |
| v0.2 | Server-side document decoding — no native code, no JitPack, passport JPEG-2000 handled server-side | ✅ |
| v0.2.1 | All traffic over HTTPS (`https://www.e-kyc.online`) — no cleartext permission needed | ✅ |
| next | Theming API, localization (strings are French today) | ⏳ |

`package:cortixia_kyc_sdk/nfc.dart` re-exports the vendored dmrtd fork for
hosts that need low-level chip access.

## Licence

Proprietary — © 2026 Cortixia. Use requires an active subscription; see
[LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
