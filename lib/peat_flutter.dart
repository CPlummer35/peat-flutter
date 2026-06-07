import 'dart:ffi';
import 'dart:io';

export 'src/peat_node.dart'
    show
        PeatFlutterNode,
        NodeConfig,
        DocumentChange,
        OutboundFrame,
        ChangeType,
        PeatError;

/// Opens the peat_ffi native library for the current platform.
///
/// On iOS peat-ffi is statically linked into the app binary; all other
/// platforms load a shared library by name.
DynamicLibrary openPeatFfiLib() {
  if (Platform.isIOS) {
    // Statically linked via ios/Frameworks/PeatFFI.xcframework.
    return DynamicLibrary.process();
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libpeat_ffi.so');
  }
  if (Platform.isMacOS) {
    return DynamicLibrary.open('libpeat_ffi.dylib');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('peat_ffi.dll');
  }
  throw UnsupportedError(
      'peat_flutter: unsupported platform ${Platform.operatingSystem}');
}
