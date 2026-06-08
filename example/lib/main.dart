import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' show min;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:peat_flutter/peat_flutter.dart';
import 'package:peat_flutter/src/generated/peat_ffi.dart' show SyncStats;

/// A single document change event for the activity feed.
class _ChangeEntry {
  final String changeType; // 'upsert' | 'delete'
  final String collection;
  final String docId;
  final String? contentPreview; // first 80 chars of JSON, pretty-ish
  final DateTime timestamp;

  _ChangeEntry({
    required this.changeType,
    required this.collection,
    required this.docId,
    this.contentPreview,
    required this.timestamp,
  });

  String get shortDocId {
    final parts = docId.split('-');
    if (parts.length >= 2) return '${parts.last.substring(0, min(8, parts.last.length))}';
    return docId.length > 8 ? '${docId.substring(0, 8)}…' : docId;
  }

  String get relativeTime {
    final diff = DateTime.now().difference(timestamp);
    if (diff.inSeconds < 2) return 'now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }
}

void main() {
  PeatFlutterNode.initialize();
  runApp(const PeatExampleApp());
}

class PeatExampleApp extends StatelessWidget {
  const PeatExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'peat_flutter example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const PeatExampleHome(),
    );
  }
}

class PeatExampleHome extends StatefulWidget {
  const PeatExampleHome({super.key});

  @override
  State<PeatExampleHome> createState() => _PeatExampleHomeState();
}

class _PeatExampleHomeState extends State<PeatExampleHome> {
  PeatFlutterNode? _node;
  String? _nodeId;
  String _hostName = '';
  String? _error;
  bool _starting = false;
  bool _stopping = false;
  bool _bleRunning = false;
  int _bleFrameCount = 0;
  final List<_ChangeEntry> _changeLog = [];
  Timer? _changeLogTimer; // drives relative-time refresh
  // Docs that already existed at subscription time — don't surface as new events.
  final Set<String> _knownAtSubscribe = {};
  List<String> _peers = [];
  SyncStats? _syncStats;
  Timer? _peerTimer;

  // PN-Counter CRDT: each node maintains its own (inc, dec) slot so
  // offline edits from multiple nodes merge additively on reconnect.
  // Total = Σ (inc_i - dec_i) across all nodes.
  static const _counterCollection = 'demo';
  // My own slot key — unique per node: "counter-macOS·H42" etc.
  String get _myCounterDoc => 'counter-${_hostName.replaceAll(' ', '_').replaceAll('·', '-')}';
  int _myInc = 0;
  int _myDec = 0;
  bool _counterDirty = false; // local edits not yet flushed to store
  // Contributions from peers: docId → (inc - dec)
  final Map<String, int> _peerContributions = {};
  // Friendly name for each peer's counter slot
  final Map<String, String> _peerNames = {};
  int get _counterValue => (_myInc - _myDec) + _peerContributions.values.fold(0, (a, b) => a + b);
  String? _counterLastBy;
  Timer? _counterTimer;
  StreamSubscription<DocumentChange>? _changeSub;
  StreamSubscription<OutboundFrame>? _outboundSub;
  int _publishCount = 0;

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    if (Platform.isIOS) {
      _hostName = 'iPhone (simulator)';
    } else if (Platform.isMacOS) {
      _hostName = 'macOS · ${Platform.localHostname.split('.').first}';
    } else {
      _hostName = Platform.operatingSystem;
    }
  }

  Future<void> _startNode() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final dir = await getApplicationSupportDirectory();
      final node = PeatFlutterNode.create(NodeConfig(
        appId: 'peat-flutter-example',
        // Test-only shared key. Replace with a real base64-encoded 32-byte key:
        //   openssl rand -base64 32
        // WARNING: all-zeros key → every example instance on the same LAN will
        // mesh with each other. Fine for local dev; replace before sharing.
        sharedKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        bindAddress: null,
        storagePath: '${dir.path}/peat',
        transport: null,
      ));
      node.startSync();

      // On connect: flush offline edits + read peer contributions.
      _refreshCounter(node);
      _counterTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (!mounted || _node == null) return;
        _refreshCounter(_node!);
      });

      _peerTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (!mounted || _node == null) return;
        setState(() {
          _peers = _node!.connectedPeers;
          _syncStats = _node!.syncStats;
        });
      });

      // Refresh relative timestamps every 10 s
      _changeLogTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (mounted) setState(() {});
      });

      // Snapshot all docs that already exist so we don't flood the feed
      // with historical entries when the peer syncs on connect.
      _knownAtSubscribe.clear();
      for (final col in ['test', 'demo']) {
        try {
          for (final id in node.listDocuments(col)) {
            _knownAtSubscribe.add('$col/$id');
          }
        } catch (_) {}
      }

      final sub = node.subscribeChanges().listen((change) {
        if (!mounted) return;
        final key = '${change.collection}/${change.docId}';
        // Skip docs that were already in the store when we subscribed.
        if (_knownAtSubscribe.contains(key)) {
          _knownAtSubscribe.remove(key); // allow re-appearance on next change
          return;
        }
        // Fetch content for preview while we still have a reference to node.
        String? preview;
        try {
          final raw = node.getRaw(change.collection, change.docId);
          if (raw != null) {
            final map = jsonDecode(raw) as Map<String, dynamic>?;
            if (map != null) {
              // Counter docs: show net value prominently
              if (change.docId.startsWith('counter-') || change.docId == 'counter') {
                final inc = map['inc'] as int? ?? 0;
                final dec = map['dec'] as int? ?? 0;
                final by = map['by'] as String? ?? '';
                preview = 'value: ${inc - dec}  ·  by: $by';
              } else {
                preview = map.entries
                    .take(3)
                    .map((e) {
                      final v = e.value?.toString() ?? 'null';
                      return '${e.key}: ${v.length > 20 ? '${v.substring(0, 20)}…' : v}';
                    })
                    .join('  ·  ');
              }
            } else {
              preview = raw.length > 60 ? '${raw.substring(0, 60)}…' : raw;
            }
          }
        } catch (_) {}
        setState(() {
          _changeLog.insert(0, _ChangeEntry(
            changeType: change.changeType.name,
            collection: change.collection,
            docId: change.docId,
            contentPreview: preview,
            timestamp: DateTime.now(),
          ));
          if (_changeLog.length > 50) _changeLog.removeLast();
        });
      });

      setState(() {
        _node = node;
        _nodeId = node.nodeId;
        _changeSub = sub;
        _starting = false;
      });
    } catch (e) {
      setState(() {
        _error = e is UnimplementedError
            ? 'Run `just gen-bindings` to generate Rust→Dart FFI bindings, '
                'then rebuild the example.'
            : 'Failed to start node: $e';
        _starting = false;
      });
    }
  }

  void _refreshCounter(PeatFlutterNode node) {
    // Flush local dirty edits first (offline changes take precedence).
    if (_counterDirty) {
      _flushMyCounter(node);
    }
    // Read all counter docs to collect peer contributions.
    final docs = node.listDocuments(_counterCollection);
    final updated = <String, int>{};
    for (final docId in docs) {
      if (!docId.startsWith('counter-')) continue;
      if (docId == _myCounterDoc) {
        // Restore my own state if we don't have it yet.
        if (_myInc == 0 && _myDec == 0 && !_counterDirty) {
          try {
            final raw = node.getRaw(_counterCollection, docId);
            if (raw != null) {
              final map = jsonDecode(raw) as Map<String, dynamic>;
              if (mounted) setState(() {
                _myInc = map['inc'] as int? ?? 0;
                _myDec = map['dec'] as int? ?? 0;
              });
            }
          } catch (_) {}
        }
        continue;
      }
      try {
        final raw = node.getRaw(_counterCollection, docId);
        if (raw != null) {
          final map = jsonDecode(raw) as Map<String, dynamic>;
          updated[docId] = (map['inc'] as int? ?? 0) - (map['dec'] as int? ?? 0);
          final by = map['by'] as String?;
          if (by != null) _peerNames[docId] = by;
        }
      } catch (_) {}
    }
    if (mounted && updated != _peerContributions) {
      setState(() => _peerContributions
        ..clear()
        ..addAll(updated));
    }
  }

  void _flushMyCounter(PeatFlutterNode node) {
    final json = jsonEncode({'inc': _myInc, 'dec': _myDec, 'by': _hostName});
    node.publishRaw(_counterCollection, json, docId: _myCounterDoc);
    setState(() {
      _counterDirty = false;
      _counterLastBy = _hostName;
    });
  }

  void _writeCounter(PeatFlutterNode? node, bool increment) {
    setState(() {
      if (increment) _myInc++; else _myDec++;
      _counterLastBy = _hostName;
    });
    if (node != null) {
      _flushMyCounter(node);
    } else {
      setState(() => _counterDirty = true);
    }
  }

  Widget _contribChip({
    required BuildContext context,
    required String label,
    required int value,
    required ThemeData theme,
    required bool isMe,
  }) {
    final color = isMe ? theme.colorScheme.primary : theme.colorScheme.secondary;
    // Shorten label: "macOS · H42W5J2K26" → "macOS", "iPhone (simulator)" → "iPhone"
    final shortLabel = label.split(' ·').first.split(' (').first.trim();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        '$shortLabel: $value',
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Color _collectionColor(String collection, ThemeData theme) {
    // Stable color per collection name
    final colors = [
      Colors.blue, Colors.purple, Colors.teal,
      Colors.orange, Colors.pink, Colors.indigo,
    ];
    return colors[collection.hashCode.abs() % colors.length];
  }

  void _publishTest() {
    final node = _node;
    if (node == null) return;
    final count = ++_publishCount;
    try {
      final docId = node.publishRaw(
        'test',
        '{"seq":$count,"ts":${DateTime.now().millisecondsSinceEpoch}}',
      );
      // The subscription listener will add this to the change feed.
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _startBle() {
    final node = _node;
    if (node == null || _bleRunning) return;
    // On mobile, Dart owns the radio via flutter_blue_plus:
    //   1. Add `flutter_blue_plus` to example/pubspec.yaml.
    //   2. Call FlutterBluePlus.scan() and connect to peat peripherals.
    //   3. On each GATT notification, call peat-btle's onBleDataReceived() to
    //      strip GATT framing / decrypt → postcardBytes.
    //   4. Feed postcardBytes to node.ingestInboundFrame(collection, bytes).
    // Outbound frames produced by Rust are received here and must be written
    // as GATT characteristics to connected peripherals.
    try {
      final sub = node.startOutboundFrames().listen((frame) {
        if (!mounted) return;
        setState(() => _bleFrameCount++);
        // TODO: write frame.bytes to the GATT characteristic for frame.transportId
      });
      setState(() {
        _outboundSub = sub;
        _bleRunning = true;
        _bleFrameCount = 0;
      });
    } catch (e) {
      setState(() => _error = 'BLE fan-out failed: $e');
    }
  }

  void _stopBle() {
    _outboundSub?.cancel();
    setState(() {
      _outboundSub = null;
      _bleRunning = false;
    });
  }

  void _stopNode() {
    setState(() => _stopping = true);
    _changeSub?.cancel();
    _outboundSub?.cancel();
    _peerTimer?.cancel();
    _counterTimer?.cancel();
    _changeLogTimer?.cancel();
    try { _node?.dispose(); } catch (_) {}
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) setState(() => _stopping = false);
    });
    setState(() {
      _node = null;
      _nodeId = null;
      _changeSub = null;
      _outboundSub = null;
      _peerTimer = null;
      _counterTimer = null;
      _peers = [];
      _syncStats = null;
      _counterLastBy = null;
      _peerNames.clear();
      _knownAtSubscribe.clear();
      _stopping = false;
      // Keep _myInc/_myDec/_counterDirty/_peerContributions so offline
      // edits and peer values persist across stop/start cycles.
      _bleRunning = false;
      _bleFrameCount = 0;
    });
  }

  @override
  void dispose() {
    _changeSub?.cancel();
    _outboundSub?.cancel();
    _peerTimer?.cancel();
    _counterTimer?.cancel();
    _changeLogTimer?.cancel();
    _node?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasNode = _node != null;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('peat_flutter example'),
        backgroundColor: theme.colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---- status / error banner ----
            if (_error != null)
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                        fontSize: 13),
                  ),
                ),
              ),

            if (_nodeId != null) ...[
              const SizedBox(height: 4),
              Text('$_hostName',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              Text(
                '${_nodeId!.substring(0, 8)}…${_nodeId!.substring(_nodeId!.length - 8)}',
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 4),
              Row(children: [
                Icon(
                  _peers.isEmpty ? Icons.wifi_off : Icons.wifi,
                  size: 14,
                  color: _peers.isEmpty ? theme.colorScheme.outline : Colors.green,
                ),
                const SizedBox(width: 4),
                Text(
                  _peers.isEmpty
                      ? 'No peers connected'
                      : '${_peers.length} peer${_peers.length == 1 ? '' : 's'} connected',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _peers.isEmpty ? theme.colorScheme.outline : Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ]),
              if (_peers.isNotEmpty)
                ...(_peers.map((p) => Text(
                  '  • ${p.length > 16 ? '${p.substring(0, 8)}…${p.substring(p.length - 8)}' : p}',
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ))),
              if (_syncStats != null)
                Text(
                  '↑${_syncStats!.bytesSent}B  ↓${_syncStats!.bytesReceived}B',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.outline,
                  ),
                ),
            ],

            const SizedBox(height: 12),

            // ---- node start/stop ----
            FilledButton(
              onPressed: (_starting || _stopping) ? null : (hasNode ? _stopNode : _startNode),
              child: Text(_starting
                  ? 'Starting…'
                  : (_stopping ? 'Stopping…' : (hasNode ? 'Stop Node' : 'Start Node'))),
            ),

            // ---- shared CRDT counter (always visible) ----
            const SizedBox(height: 16),
            Card(
              color: _counterDirty
                  ? theme.colorScheme.tertiaryContainer.withOpacity(0.4)
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Shared Counter',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        if (!hasNode)
                          Chip(
                            label: const Text('✈ offline'),
                            labelStyle: theme.textTheme.labelSmall,
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          )
                        else if (_counterDirty)
                          Chip(
                            label: const Text('⟳ syncing'),
                            labelStyle: theme.textTheme.labelSmall,
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton.filledTonal(
                          icon: const Icon(Icons.remove),
                          iconSize: 28,
                          onPressed: () => _writeCounter(_node, false),
                        ),
                        const SizedBox(width: 24),
                        Text(
                          '$_counterValue',
                          style: theme.textTheme.displaySmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 24),
                        IconButton.filledTonal(
                          icon: const Icon(Icons.add),
                          iconSize: 28,
                          onPressed: () => _writeCounter(_node, true),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Per-node contribution breakdown
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        _contribChip(
                          context: context,
                          label: 'You',
                          value: _myInc - _myDec,
                          theme: theme,
                          isMe: true,
                        ),
                        ..._peerContributions.entries.map((e) => _contribChip(
                          context: context,
                          label: _peerNames[e.key] ?? e.key.replaceFirst('counter-', '').replaceAll('_', ' '),
                          value: e.value,
                          theme: theme,
                          isMe: false,
                        )),
                      ],
                    ),
                    if (_counterLastBy != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'last write: $_counterLastBy',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // ---- mobile BLE section ----
            if (hasNode && _isMobile) ...[
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: _bleRunning ? _stopBle : _startBle,
                child: Text(_bleRunning
                    ? 'Stop BLE ($_bleFrameCount outbound frames)'
                    : 'Start BLE Outbound'),
              ),
            ],

            const SizedBox(height: 16),
            Row(children: [
              Text('Document changes', style: theme.textTheme.titleSmall),
              const Spacer(),
              if (_changeLog.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _changeLog.clear()),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text('clear', style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
                ),
            ]),
            const Divider(height: 8),

            // ---- activity feed ----
            Expanded(
              child: _changeLog.isEmpty
                  ? Center(
                      child: Text(
                        hasNode
                            ? 'No changes yet — publish a doc to see activity.'
                            : 'Start a node to see document activity.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                        textAlign: TextAlign.center,
                      ))
                  : ListView.separated(
                      itemCount: _changeLog.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 48),
                      itemBuilder: (_, i) {
                        final e = _changeLog[i];
                        final collColor = _collectionColor(e.collection, theme);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Collection badge
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: collColor.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Center(
                                  child: Text(
                                    e.collection.substring(0, min(3, e.collection.length)).toUpperCase(),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: collColor,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              // Content
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(children: [
                                      Text(
                                        '${e.collection} / ${e.shortDocId}',
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          fontWeight: FontWeight.w600,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: e.changeType == 'upsert'
                                              ? Colors.green.withOpacity(0.15)
                                              : Colors.red.withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          e.changeType,
                                          style: theme.textTheme.labelSmall?.copyWith(
                                            color: e.changeType == 'upsert'
                                                ? Colors.green.shade700
                                                : Colors.red.shade700,
                                          ),
                                        ),
                                      ),
                                    ]),
                                    if (e.contentPreview != null)
                                      Text(
                                        e.contentPreview!,
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: theme.colorScheme.onSurface.withOpacity(0.7),
                                          fontFamily: 'monospace',
                                          fontSize: 11,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                  ],
                                ),
                              ),
                              // Relative time
                              Text(
                                e.relativeTime,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
