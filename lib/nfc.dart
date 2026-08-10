/// Re-export of the vendored dmrtd fork (eMRTD + Algerian IDL applet).
///
/// Host code should import this instead of `package:dmrtd/...` so it does not
/// need its own dependency on the vendored fork. Transitional API — once the
/// scan flows move fully inside the SDK (Phase A2), host apps will not need
/// NFC-level access at all.
library;

export 'package:dmrtd/dmrtd.dart';
export 'package:dmrtd/extensions.dart';
