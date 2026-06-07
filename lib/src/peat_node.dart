// peat_flutter — Dart facade over the UniFFI-generated peat-ffi bindings.
//
// Setup: before this file compiles against the real generated types, run:
//   just gen-bindings   → generates lib/src/generated/peat_ffi.dart
//   just gen-proto      → generates lib/src/proto/*.pb.dart
//
// After generation:
//   1. Delete the SCAFFOLD TYPES section below.
//   2. Uncomment the two imports that follow.
//   3. Run `dart analyze lib/` to verify.

// import 'generated/peat_ffi.dart';          // uncomment after gen-bindings
// import 'proto/cap.unified.pb.dart';         // example; import the proto you need

import 'dart:async';
import 'dart:typed_data';
import 'package:protobuf/protobuf.dart';

// ===========================================================================
// SCAFFOLD TYPES — delete and replace with generated import after gen-bindings
// These names and shapes are derived from the peat-ffi UniFFI surface analysis
// (Phase 0). Discrepancies will surface as type errors when the generated code
// is substituted in.
// ===========================================================================

/// Configuration for creating a [PeatFlutterNode].
/// Maps to peat-ffi's `NodeConfig` UniFFI record.
class NodeConfig {
  final String appId;
  final String sharedKey;
  final String? bindAddress;
  final String storagePath;

  const NodeConfig({
    required this.appId,
    required this.sharedKey,
    this.bindAddress,
    required this.storagePath,
  });
}

/// The kind of document mutation reported by [DocumentChange].
/// Maps to peat-ffi's `ChangeType` UniFFI enum.
enum ChangeType { upsert, delete }

/// A document change event received from the mesh.
/// Maps to peat-ffi's `DocumentChange` UniFFI record.
class DocumentChange {
  final String collection;
  final String docId;
  final ChangeType changeType;

  const DocumentChange({
    required this.collection,
    required this.docId,
    required this.changeType,
  });
}

/// A BLE outbound frame to be handed to the radio.
/// Maps to peat-ffi's `OutboundFrame` UniFFI record.
/// [transportId] is `"ble"` (typed 0xB6 frame) or `"ble-lite"` (peat-lite).
class OutboundFrame {
  final String transportId;
  final String collection;
  final List<int> bytes;

  const OutboundFrame({
    required this.transportId,
    required this.collection,
    required this.bytes,
  });
}

/// Error thrown by peat-ffi operations.
/// Maps to peat-ffi's `PeatError` UniFFI error enum.
class PeatError implements Exception {
  final String message;
  const PeatError(this.message);
  @override
  String toString() => 'PeatError: $message';
}

/// Handle for an active document subscription. Kept alive to receive events.
/// Maps to peat-ffi's `SubscriptionHandle` UniFFI object.
abstract class SubscriptionHandle {
  bool isActive();
  void cancel();

  /// Drain all pending [DocumentChange] events. Non-blocking.
  /// Only populated when opened via [subscribePoll]; always empty for
  /// callback-based subscriptions.
  List<DocumentChange> pollChanges();
}

/// Internal bridge to the generated UniFFI `PeatNode` object.
/// Replace with the generated `PeatNode` from `src/generated/peat_ffi.dart`.
abstract class _PeatNodeFfi {
  String nodeId();
  void startSync();
  String publishDocument(String collection, String jsonData);
  String? getDocument(String collection, String docId);
  List<String> listDocuments(String collection);

  /// Poll-based subscription — no foreign callback needed.
  SubscriptionHandle subscribePoll();

  void startOutboundFrames();
  List<OutboundFrame> pollOutboundFrames();
  void stopOutboundFrames();

  /// Decode [postcardBytes] for [collection] and publish into the mesh.
  /// Returns the document ID, or null for an unknown/declined frame.
  String? ingestInboundFrame(String collection, Uint8List postcardBytes);
}

// ===========================================================================
// END SCAFFOLD TYPES
// ===========================================================================

/// Idiomatic Dart wrapper around the peat-ffi [PeatNode] UniFFI object.
///
/// Exposes document publish/get and [Stream]-based change + BLE-outbound
/// subscriptions backed by the poll API added in peat-ffi 0.2.6.
///
/// Create via [PeatFlutterNode.create]:
/// ```dart
/// final node = PeatFlutterNode.create(NodeConfig(
///   appId: 'my-app',
///   sharedKey: base64Key,
///   storagePath: appDir.path,
/// ));
/// node.startSync();
///
/// final sub = node.subscribeChanges();
/// sub.listen((change) => print('${change.collection}/${change.docId}'));
/// ```
class PeatFlutterNode {
  // Replace `_PeatNodeFfi` with the generated `PeatNode` type after gen-bindings.
  final _PeatNodeFfi _node;

  Timer? _changeTimer;
  Timer? _outboundTimer;
  SubscriptionHandle? _subscription;
  StreamController<DocumentChange>? _changeCtrl;
  StreamController<OutboundFrame>? _outboundCtrl;

  PeatFlutterNode._(this._node);

  // Replace `_PeatNodeFfi` with `PeatNode` and `_createNode` with
  // the generated `createNode(config)` after gen-bindings.
  static PeatFlutterNode create(NodeConfig config) {
    throw UnimplementedError(
      'Run `just gen-bindings` and replace this stub implementation. '
      'Substitute: return PeatFlutterNode._(createNode(config));',
    );
  }

  /// This node's hex-encoded unique identifier.
  String get nodeId => _node.nodeId();

  /// Start mesh synchronisation over Iroh QUIC / BLE (desktop) or
  /// the registered translators (mobile).
  void startSync() => _node.startSync();

  /// Publish [message] (a proto-generated [GeneratedMessage]) into [collection].
  ///
  /// The message is JSON-encoded at the FFI boundary; the mesh stores it as
  /// an Automerge document. Returns the opaque document ID.
  String publishMessage(String collection, GeneratedMessage message) {
    return _node.publishDocument(collection, message.writeToJson());
  }

  /// Publish raw [jsonData] into [collection] without proto encoding.
  /// Useful for testing and for consumers that manage their own serialisation.
  /// Returns the opaque document ID.
  String publishRaw(String collection, String jsonData) {
    return _node.publishDocument(collection, jsonData);
  }

  /// Retrieve a document as a proto message, or null if not found.
  ///
  /// Pass the empty [defaultInstance] for the message type you expect:
  /// ```dart
  /// final track = node.getMessage('tracks', docId, Track());
  /// ```
  T? getMessage<T extends GeneratedMessage>(
    String collection,
    String docId,
    T defaultInstance,
  ) {
    final json = _node.getDocument(collection, docId);
    if (json == null) return null;
    return (defaultInstance.createEmptyInstance()..mergeFromJson(json)) as T;
  }

  /// List all document IDs in [collection].
  List<String> listDocuments(String collection) => _node.listDocuments(collection);

  /// A broadcast [Stream] of document change events for this node.
  ///
  /// Internally calls [SubscriptionHandle.pollChanges] every [pollInterval]
  /// (default 50 ms) — no foreign callback needed. Cancelling the
  /// subscription or calling [dispose] stops the underlying poll timer.
  Stream<DocumentChange> subscribeChanges({
    Duration pollInterval = const Duration(milliseconds: 50),
  }) {
    _changeTimer?.cancel();
    _changeCtrl?.close();
    _subscription?.cancel();

    final sub = _node.subscribePoll();
    _subscription = sub;

    final ctrl = StreamController<DocumentChange>.broadcast(
      onCancel: () {
        _changeTimer?.cancel();
        sub.cancel();
      },
    );
    _changeCtrl = ctrl;

    _changeTimer = Timer.periodic(pollInterval, (_) {
      if (ctrl.isClosed) return;
      for (final c in sub.pollChanges()) {
        ctrl.add(c);
      }
    });

    return ctrl.stream;
  }

  /// Registers the BLE translator fan-out and returns a broadcast [Stream] of
  /// outbound frames. For mobile Dart-owned BLE (Android/iOS), hand each
  /// [OutboundFrame.bytes] to the radio after your GATT framing + encryption.
  ///
  /// On desktop, Rust owns the radio via peat-btle's bluer/CoreBluetooth/WinRT
  /// backends — this stream is unused and may not emit.
  ///
  /// Cancelling the stream or calling [dispose] calls
  /// [PeatNode.stopOutboundFrames] on the FFI side.
  Stream<OutboundFrame> startOutboundFrames({
    Duration pollInterval = const Duration(milliseconds: 50),
  }) {
    _outboundTimer?.cancel();
    _outboundCtrl?.close();

    _node.startOutboundFrames();

    final ctrl = StreamController<OutboundFrame>.broadcast(
      onCancel: () {
        _outboundTimer?.cancel();
        _node.stopOutboundFrames();
      },
    );
    _outboundCtrl = ctrl;

    _outboundTimer = Timer.periodic(pollInterval, (_) {
      if (ctrl.isClosed) return;
      for (final f in _node.pollOutboundFrames()) {
        ctrl.add(f);
      }
    });

    return ctrl.stream;
  }

  /// Feed a BLE inbound frame (postcard bytes from peat-btle) into the mesh.
  ///
  /// Mobile flow:
  ///   flutter_blue_plus → peat-btle.onBleDataReceived → postcardBytes
  ///   → ingestInboundFrame → Automerge publish → subscribeChanges stream.
  ///
  /// Returns the document ID if the frame was accepted, null if the collection
  /// was not recognised by the translator.
  String? ingestInboundFrame(String collection, Uint8List postcardBytes) {
    return _node.ingestInboundFrame(collection, postcardBytes);
  }

  /// Cancel all active subscriptions and timers. Call when the node is no
  /// longer needed to avoid timer leaks.
  void dispose() {
    _changeTimer?.cancel();
    _outboundTimer?.cancel();
    _changeCtrl?.close();
    _outboundCtrl?.close();
    _subscription?.cancel();
    try {
      _node.stopOutboundFrames();
    } catch (_) {}
  }
}
