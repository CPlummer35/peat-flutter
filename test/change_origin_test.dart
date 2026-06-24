// Copyright 2026 Defense Unicorns
// SPDX-License-Identifier: Apache-2.0

// Tests for DocumentChange.origin — the ChangeOrigin JSON codec (both variants)
// and the ChangeOrigin Dart surface.
//
// The binary FFI decode path (_uniffiReadChangeOrigin / _uniffiReadDocumentChange)
// requires the native library and is exercised by the smoke_reconnect tool
// (Local variant) and by real cross-peer sync (Remote variant). The
// native-linux-arm64 CI job validates symbol presence but not decode round-trips.

import 'package:flutter_test/flutter_test.dart';
import 'package:peat_flutter/peat_flutter.dart';

void main() {
  group('ChangeOrigin — JSON round-trip', () {
    const collection = 'test';
    const docId = 'doc-1';
    const changeTypeStr = 'upsert';

    Map<String, dynamic> baseJson({String? origin}) => {
          'collection': collection,
          'docId': docId,
          'changeType': changeTypeStr,
          'origin': origin,
        };

    test('Local origin: null origin field decodes to isLocal=true', () {
      final change = DocumentChange.fromJson(baseJson(origin: null));
      expect(change.origin.isLocal, isTrue);
      expect(change.origin.peerId, isNull);
    });

    test('Local origin: toJson emits null origin field', () {
      final change = DocumentChange.fromJson(baseJson(origin: null));
      expect(change.toJson()['origin'], isNull);
    });

    test('Remote origin: non-null origin field decodes to isRemote=true', () {
      const peerId = 'abc123deadbeef';
      final change = DocumentChange.fromJson(baseJson(origin: peerId));
      expect(change.origin.isLocal, isFalse);
      expect(change.origin.peerId, equals(peerId));
    });

    test('Remote origin: toJson round-trips peer id', () {
      const peerId = 'abc123deadbeef';
      final change = DocumentChange.fromJson(baseJson(origin: peerId));
      expect(change.toJson()['origin'], equals(peerId));
    });

    test('copyWith preserves origin when not overridden', () {
      const peerId = 'peer-xyz';
      final original = DocumentChange.fromJson(baseJson(origin: peerId));
      final copied = original.copyWith(docId: 'doc-2');
      expect(copied.origin.peerId, equals(peerId));
    });

    test('equality considers origin', () {
      final local = DocumentChange.fromJson(baseJson(origin: null));
      final remote = DocumentChange.fromJson(baseJson(origin: 'peer-1'));
      expect(local, isNot(equals(remote)));
    });
  });
}
