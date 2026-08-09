// Created by Crt Vavros, copyright © 2022 ZeroPass. All rights reserved.
import 'dart:typed_data';
import 'package:dmrtd/dmrtd.dart';
import 'package:dmrtd/extensions.dart';
import 'package:logging/logging.dart';

import 'proto/iso7816/icc.dart';
import 'proto/iso7816/response_apdu.dart';
import 'proto/mrtd_api.dart';


class PassportError implements Exception {
  final String message;
  final StatusWord? code;
  PassportError(this.message, {this.code});
  @override
  String toString() => message;
}

enum _DF {
  // ignore: constant_identifier_names
  None,
  // ignore: constant_identifier_names
  MF,
  // ignore: constant_identifier_names
  DF1,
  // ignore: constant_identifier_names
  DL
}

class Passport {
  static const aaChallengeLen = 8;

  final _log = Logger("passport");
  final MrtdApi _api;
  _DF _dfSelectd = _DF.None;

  /// Last DBAKeys handed to startSession/startDlSession. Stored so we can
  /// re-establish the SM session on demand (e.g. after an SM-breaking
  /// error from the chip while reading large EFs).
  DBAKeys? _lastBacKeys;
  bool _lastSessionWasDl = false;

  /// Constructs new [Passport] instance with communication [provider].
  /// [provider] should be already connected.
  Passport(final ComProvider provider) : _api = MrtdApi(provider);

  /// Starts new Secure Messaging session with passport
  /// using Document Basic Access [keys].
  ///
  /// Can throw [ComProviderError] on connection failure.
  /// Throws [PassportError] when provided [keys] are invalid or
  /// if BAC session is not supported.
  Future<void> startSession(final DBAKeys keys) async {
    _log.debug("Starting session");
    await _selectDF1();
    await _exec(() => _api.initSessionViaBAC(keys));
    _lastBacKeys = keys;
    _lastSessionWasDl = false;
    _log.debug("Session established");
  }

  /// Like [startSession] but selects the ISO/IEC 18013-3 IDL applet
  /// (AID A0000002480200) instead of the ICAO 9303 eMRTD applet.
  /// Used for Algerian driving licence chips, which expose the IDL
  /// applet but otherwise share the BAC handshake and EF layout.
  ///
  /// If [force] is true, the IDL applet is re-selected even if we're
  /// already in it — this resets any half-state the chip may have
  /// from a prior failed BAC attempt. Call with [force] = true on
  /// retry after a transient 6982/63CF.
  ///
  /// Can throw [ComProviderError] on connection failure.
  /// Throws [PassportError] when provided [keys] are invalid or
  /// if BAC session is not supported by the IDL applet.
  Future<void> startDlSession(final DBAKeys keys, {bool force = false}) async {
    _log.debug("Starting DL session (force=$force)");
    if (force) {
      _dfSelectd = _DF.None;
      _api.icc.sm = null;
    }
    await _selectDL();
    await _exec(() => _api.initSessionViaBAC(keys));
    _lastBacKeys = keys;
    _lastSessionWasDl = true;
    _log.debug("DL session established");
  }

  /// Re-establish the SM session by re-selecting the application
  /// (eMRTD or IDL based on which session was last started) and re-
  /// running BAC. Useful after an SM-breaking chip error like SW=6987
  /// or 6882 — without this, a single bad chunk poisons every
  /// subsequent read on this connection.
  ///
  /// Throws [PassportError] if no BAC keys are remembered (i.e. no
  /// session was ever started) or if reinit fails.
  Future<void> reinitSmSession() async {
    final keys = _lastBacKeys;
    if (keys == null) {
      throw PassportError("Cannot reinit SM: no prior session");
    }
    _log.debug("Reinit SM session (DL=${_lastSessionWasDl})");
    // Force re-selection of the application — the chip may have lost
    // its current-DF context too.
    _dfSelectd = _DF.None;
    _api.icc.sm = null;
    if (_lastSessionWasDl) {
      await _selectDL();
    } else {
      await _selectDF1();
    }
    await _exec(() => _api.initSessionViaBAC(keys));
    _log.debug("SM session reinit OK");
  }

  /// Executes Active Authentication command with [challenge] and
  /// returns signature bytes. The [challenge] should be 8 bytes long.
  /// Session with passport should be already established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if invalid [challenge] length, AA is not supported
  /// or if calling this function prior establishing session with passport.
  ///
  /// Note: AA is not available if EF.DG15 file is missing from passport.
  ///       Read EF.COM file To determine if file EF.DG15.
  Future<Uint8List> activeAuthenticate(final Uint8List challenge) async {
    return await _exec(() =>
      _api.activeAuthenticate(challenge)
    );
  }

  /// Reads file EF.CardAccess from passport.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist.
  ///
  /// Note: Might not be available if PACE is not supported
  Future<EfCardAccess> readEfCardAccess() async {
    _log.debug("Reading EF.CardAccess");
    await _selectMF();
    return EfCardAccess.fromBytes(
      await _exec(() => _api.readFileBySFI(EfCardAccess.SFI))
    );
  }

  /// Reads file EF.CardSecurity from passport.
  /// Session with passport via PACE protocol
  /// should be established prior calling this function.
  ///
  /// Note: PACE protocol is not supported yet.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if session was not established via PACE protocol.
  Future<EfCardSecurity> readEfCardSecurity() async {
    _log.debug("Reading EF.CardSecurity");
    await _selectMF();
    return EfCardSecurity.fromBytes(
      await _exec(() => _api.readFileBySFI(EfCardSecurity.SFI))
    );
  }

  /// Reads file EF.COM from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  Future<EfCOM> readEfCOM() async {
    _log.debug("Reading EF.COM");
    await _selectDF1();
    return EfCOM.fromBytes(
      await _exec(() => _api.readFileBySFI(EfCOM.SFI))
    );
  }

  /// Reads file EF.DG1 from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  Future<EfDG1> readEfDG1() async {
    await _selectDF1();
    _log.debug("Reading EF.DG1");
    return EfDG1.fromBytes(
      await _exec(() => _api.readFileBySFI(EfDG1.SFI))
    );
  }

  /// Reads file EF.DG2 from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  Future<EfDG2> readEfDG2() async {
    _log.debug("Reading EF.DG2");
    await _selectDF1();
    return EfDG2.fromBytes(
      await _exec(() => _api.readFileBySFI(EfDG2.SFI))
    );
  }

  /// Reads file EF.DG3 from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  /// [PassportError] is also thrown if extended authentication is required
  /// but wasn't successfully executed first.
  ///
  /// Note: Extended authentication not supported.
  Future<EfDG3> readEfDG3() async {
    _log.debug("Reading EF.DG3");
    await _selectDF1();
    return EfDG3.fromBytes(
      await _exec(() => _api.readFileBySFI(EfDG3.SFI))
    );
  }

  /// Reads file EF.DG4 from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  /// [PassportError] is also thrown if extended authentication is required
  /// but wasn't successfully executed first.
  ///
  /// Note: Extended authentication not supported.
  Future<EfDG4> readEfDG4() async {
    _log.debug("Reading EF.DG4");
    await _selectDF1();
    return EfDG4.fromBytes(
      await _exec(() => _api.readFileBySFI(EfDG4.SFI))
    );
  }

  /// Reads file EF.DG5 from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  Future<EfDG5> readEfDG5() async {
    _log.debug("Reading EF.DG5");
    await _selectDF1();
    return EfDG5.fromBytes(
      await _exec(() => _api.readFileBySFI(EfDG5.SFI))
    );
  }

  /// Reads file EF.DG6 from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  Future<EfDG6> readEfDG6() async {
    _log.debug("Reading EF.DG6");
    await _selectDF1();
    return EfDG6.fromBytes(
      await _exec(() => _api.readFileBySFI(EfDG6.SFI))
    );
  }

  /// Reads file EF.DG7 from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  Future<EfDG7> readEfDG7() async {
    _log.debug("Reading EF.DG7");
    await _selectDF1();
    return EfDG7.fromBytes(
      await _exec(() => _api.readFileBySFI(EfDG7.SFI))
    );
  }

  /// Reads file EF.DG8 from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  Future<EfDG8> readEfDG8() async {
    _log.debug("Reading EF.DG8");
    await _selectDF1();
    return EfDG8.fromBytes(
      await _exec(() => _api.readFileBySFI(EfDG8.SFI))
    );
  }

  /// Reads file EF.DG9 from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  Future<EfDG9> readEfDG9() async {
    _log.debug("Reading EF.DG9");
    await _selectDF1();
    return EfDG9.fromBytes(
      await _exec(() => _api.readFileBySFI(EfDG9.SFI))
    );
  }

  /// Reads file EF.DG10 from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  Future<EfDG10> readEfDG10() async {
    _log.debug("Reading EF.DG10");
    await _selectDF1();
    return EfDG10.fromBytes(
      await _exec(() => _api.readFileBySFI(EfDG10.SFI))
    );
  }

  /// Reads file EF.DG11 from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  Future<EfDG11> readEfDG11() async {
    _log.debug("Reading EF.DG11");
    await _selectDF1();
    return EfDG11.fromBytes(
      await _exec(() => _api.readFileBySFI(EfDG11.SFI))
    );
  }

  /// Reads file EF.DG12 from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  Future<EfDG12> readEfDG12() async {
    _log.debug("Reading EF.DG12");
    await _selectDF1();
    return EfDG12.fromBytes(
      await _exec(() => _api.readFileBySFI(EfDG12.SFI))
    );
  }

  /// Reads file EF.DG13 from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  Future<EfDG13> readEfDG13() async {
    _log.debug("Reading EF.DG13");
    await _selectDF1();
    return EfDG13.fromBytes(
      await _exec(() => _api.readFileBySFI(EfDG13.SFI))
    );
  }

  /// Reads file EF.DG14 from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  Future<EfDG14> readEfDG14() async {
    await _selectDF1();
    _log.debug("Reading EF.DG14");
    return EfDG14.fromBytes(
      await _exec(() => _api.readFileBySFI(EfDG14.SFI))
    );
  }

  /// Reads file EF.DG15 from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  Future<EfDG15> readEfDG15() async {
    _log.debug("Reading EF.DG15");
    await _selectDF1();
    return EfDG15.fromBytes(
      await _exec(() => _api.readFileBySFI(EfDG15.SFI))
    );
  }

  /// Reads file EF.DG16 from passport.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  Future<EfDG16> readEfDG16() async {
    _log.debug("Reading EF.DG16");
    await _selectDF1();
    return EfDG16.fromBytes(
      await _exec(() => _api.readFileBySFI(EfDG16.SFI))
    );
  }

  /// Reads file EF.SOD.
  /// Session with passport should be already
  /// established before calling this function.
  ///
  /// Can throw [ComProviderError] on connection error.
  /// Throws [PassportError] if file doesn't exist or
  /// if calling this function prior establishing session with passport.
  Future<EfSOD> readEfSOD() async {
    _log.debug("Reading EF.SOD");
    await _selectDF1();
    return EfSOD.fromBytes(
      await _exec(() => _api.readFileBySFI(EfSOD.SFI))
    );
  }

  /// Single-shot read of up to [maxBytes] bytes from EF identified by
  /// [sfi] starting at [offset]. Never throws. Returns (data, sw, error).
  /// Useful for diagnostic enumeration of the IDL applet.
  Future<({Uint8List? data, StatusWord? sw, String? error})> readEfRawBySFI(
      int sfi, {int offset = 0, int maxBytes = 96}) async {
    try {
      final rapdu = await _api.icc.readBinaryBySFI(
        sfi: sfi | 0x80,
        offset: offset,
        ne: maxBytes,
      );
      return (data: rapdu.data, sw: rapdu.status, error: null);
    } on ICCError catch (e) {
      return (data: e.data, sw: e.sw, error: null);
    } catch (e) {
      return (data: null, sw: null, error: e.toString());
    }
  }

  /// Reads the *full* contents of EF identified by [sfi]. Strategy:
  ///
  ///  1. First read uses SFI mode (P1=0x80|SFI) which implicitly selects
  ///     the EF. Reads the first [chunkSize] bytes (default 96, well under
  ///     the 224 SM-overhead limit) starting at offset 0.
  ///  2. Parse the BER-TLV header from the first read to learn total file
  ///     size.
  ///  3. Continue reading [chunkSize] bytes at a time:
  ///       - For offset 1..255: use SFI mode again (P2 = offset).
  ///       - For offset >= 256: explicit SELECT EF (file ID = 0x0100|sfi
  ///         per the ICAO/ISO convention) then plain READ BINARY with the
  ///         15-bit offset. This works around chips that don't retain the
  ///         SFI-mode selection across plain READ BINARY calls (which is
  ///         what bit dmrtd's `_readBinary` chunked loop on this chip).
  ///  4. Stop when the requested length is reached, the chip returns no
  ///     data, or SW != 9000.
  ///
  /// Returns up to [maxFileSize] bytes (default 32K — bigger than any DG).
  /// Never throws.
  ///
  /// [onProgress], if given, is called with `(bytesRead, totalSize)` once
  /// after the first chunk (so the caller knows the total size as soon as
  /// possible) and again after each subsequent chunk. Lets the UI render
  /// "Lecture: 8 / 16 KB" instead of a blank pause during the multi-second
  /// JPEG read.
  Future<({Uint8List? data, StatusWord? sw, String? error})> readEfFullBySFI(
      int sfi, {int chunkSize = 96, int maxFileSize = 32768,
      void Function(int bytesRead, int totalSize)? onProgress}) async {
    try {
      // ---- Step 1: first chunk via SFI mode ----
      final first = await _api.icc.readBinaryBySFI(
        sfi: sfi | 0x80,
        offset: 0,
        ne: chunkSize,
      );
      if (first.status != StatusWord.success || first.data == null || first.data!.isEmpty) {
        return (data: first.data, sw: first.status, error: null);
      }
      final accumulator = <int>[]..addAll(first.data!);

      // ---- Step 2: parse BER-TLV length to know total size ----
      int? totalSize = _parseTlvTotalSize(first.data!);
      if (totalSize == null) {
        // Couldn't parse — return what we have rather than spinning forever.
        return (data: Uint8List.fromList(accumulator), sw: first.status, error: 'TLV header unparseable');
      }
      if (totalSize > maxFileSize) totalSize = maxFileSize;
      onProgress?.call(accumulator.length, totalSize);
      if (totalSize <= accumulator.length) {
        return (data: Uint8List.fromList(accumulator.sublist(0, totalSize)), sw: first.status, error: null);
      }

      // ---- Step 3: continue reading chunks ----
      //
      // Past offset 255 the SFI-mode P2 (8-bit) overflows, so we have
      // to pick a different command. Things this chip does NOT accept:
      //   - SELECT EF + plain READ BINARY  → 6985 (SELECT breaks SM)
      //   - READ BINARY EXT (B1) under SM   → 6987 (B1 breaks SM)
      //
      // What we try: plain READ BINARY (`B0`, P1+P2 = 15-bit offset)
      // directly, relying on the EF selection set by the prior
      // SFI-mode read. No SELECT, no B1. If it works, great — if not
      // we surface the SW so caller can decide whether to retry/abort.

      // Adaptive chunk size: if the chip ever responds with SW=6CXX
      // ("wrong length, exact length is XX"), shrink to that size.
      int adaptiveChunk = chunkSize;

      while (accumulator.length < totalSize) {
        final offset = accumulator.length;
        final remaining = totalSize - offset;
        final ne = remaining < adaptiveChunk ? remaining : adaptiveChunk;

        Uint8List? chunkData;
        StatusWord? sw;

        try {
          if (offset < 256) {
            // SFI-mode read (P1=0x80|SFI, P2=offset). Re-asserts EF
            // selection on every call.
            final r = await _api.icc.readBinaryBySFI(
              sfi: sfi | 0x80,
              offset: offset,
              ne: ne,
            );
            chunkData = r.data;
            sw = r.status;
          } else {
            // Plain READ BINARY (B0). Relies on EF being still
            // selected from the prior SFI-mode reads. NO `SELECT EF`
            // and NO `readBinaryExt` — both have been observed to
            // break SM on this chip.
            final r = await _api.icc.readBinary(
              offset: offset,
              ne: ne,
            );
            chunkData = r.data;
            sw = r.status;
          }
        } on ICCError catch (e) {
          chunkData = e.data;
          sw = e.sw;
        }

        // SW=6CXX: chip says Le was wrong, exact length is sw2. Shrink
        // adaptive chunk and retry the same offset.
        if (sw != null && sw.sw1 == 0x6C) {
          adaptiveChunk = sw.sw2 == 0 ? 1 : sw.sw2;
          continue;
        }

        if (chunkData == null || chunkData.isEmpty) {
          return (
            data: Uint8List.fromList(accumulator),
            sw: sw ?? first.status,
            error: 'No data at offset $offset',
          );
        }

        accumulator.addAll(chunkData);
        onProgress?.call(accumulator.length, totalSize);
        if (sw != null && sw != StatusWord.success && sw.sw1 != 0x61) {
          break;
        }
      }

      return (data: Uint8List.fromList(accumulator), sw: StatusWord.success, error: null);
    } on ICCError catch (e) {
      return (data: e.data, sw: e.sw, error: null);
    } catch (e) {
      return (data: null, sw: null, error: e.toString());
    }
  }

  /// Parse BER-TLV header from the start of [bytes] and return the total
  /// encoded size (header + value). Returns null if the encoding can't be
  /// parsed from the bytes available.
  int? _parseTlvTotalSize(Uint8List bytes) {
    if (bytes.isEmpty) return null;

    // Tag — 1 byte if (bytes[0] & 0x1F) != 0x1F, else multi-byte.
    int idx = 0;
    if ((bytes[idx] & 0x1F) == 0x1F) {
      idx += 1;
      while (idx < bytes.length && (bytes[idx] & 0x80) != 0) {
        idx += 1;
      }
      if (idx >= bytes.length) return null;
      idx += 1;
    } else {
      idx += 1;
    }

    if (idx >= bytes.length) return null;

    // Length — short form (one byte, < 0x80) or long form (0x81..0x84
    // means "next N bytes are the length").
    final lenByte = bytes[idx];
    int contentLen;
    if (lenByte < 0x80) {
      contentLen = lenByte;
      idx += 1;
    } else {
      final numLenBytes = lenByte & 0x7F;
      if (numLenBytes == 0 || numLenBytes > 4) return null;
      if (idx + 1 + numLenBytes > bytes.length) return null;
      contentLen = 0;
      for (int i = 1; i <= numLenBytes; i++) {
        contentLen = (contentLen << 8) | bytes[idx + i];
      }
      idx += 1 + numLenBytes;
    }

    return idx + contentLen;
  }

  Future<void> _selectMF() async {
    if(_dfSelectd != _DF.MF) {
      _log.debug("Selecting MF");
      await _exec(() =>
        _api.selectMasterFile()
      );
      _dfSelectd = _DF.MF;
    }
  }

  Future<void> _selectDF1() async {
    // If we're already inside an application (eMRTD or IDL), don't switch —
    // the IDL applet exposes the same SFIs as eMRTD, so all the readEf*
    // methods work transparently for both. Without this check, every
    // readEf*() call after startDlSession() would re-select the eMRTD AID
    // and break the DL flow.
    if(_dfSelectd == _DF.DF1 || _dfSelectd == _DF.DL) {
      return;
    }
    _log.debug("Selecting DF1");
    await _exec(() =>
      _api.selectEMrtdApplication()
    );
    _dfSelectd = _DF.DF1;
  }

  Future<void> _selectDL() async {
    if(_dfSelectd != _DF.DL) {
      _log.debug("Selecting DL applet");
      await _exec(() =>
        _api.selectDLApplication()
      );
      _dfSelectd = _DF.DL;
    }
  }

  Future<T> _exec<T>(Function f) async {
    try {
      return await f();
    }
    on ICCError catch(e) {
      var msg = e.sw.description();
      if(e.sw.sw1 == 0x63 && e.sw.sw2 == 0xcf) {
        // some older passports return sw=63cf when data to establish session is wrong. (Wrong DBAKeys)
        msg = StatusWord.securityStatusNotSatisfied.description();
      }
      throw PassportError(msg, code: e.sw);
    }
    on MrtdApiError catch(e) {
      throw PassportError(e.message, code: e.code);
    }
  }
}