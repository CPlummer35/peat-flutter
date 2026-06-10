#
# Run `pod lib lint peat_flutter.podspec` to validate before publishing.
# Run `just build-ios` (or ios/build-rust.sh) to produce Frameworks/PeatFFI.xcframework
# before running `pod install` in an app that depends on this plugin.
#
Pod::Spec.new do |s|
  s.name             = 'peat_flutter'
  s.version          = '0.0.1'
  s.summary          = 'Flutter FFI plugin wrapping peat-ffi (peat mesh + BLE).'
  s.description      = 'UniFFI-generated Dart bindings for the peat mesh protocol — peat-schema, peat-protocol, peat-mesh, and peat-btle.'
  s.homepage         = 'https://github.com/defenseunicorns/peat-flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Defense Unicorns' => 'info@defenseunicorns.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '16.0'

  # Pre-built static xcframework containing:
  #   aarch64-apple-ios          (device)
  #   lipo(aarch64-apple-ios-sim + x86_64-apple-ios)  (simulator)
  # Produced by ios/build-rust.sh (staticlib crate-type).
  s.vendored_frameworks = 'Frameworks/PeatFFI.xcframework'

  s.dependency 'Flutter'
  # System frameworks required by peat-ffi and its Rust dependencies:
  #   Network          — iroh QUIC transport (nw_path_monitor, etc.)
  #   Security         — TLS / certificate handling
  #   SystemConfiguration — network reachability
  #   CoreBluetooth    — peat-btle BLE transport
  s.frameworks = 'Network', 'Security', 'SystemConfiguration', 'CoreBluetooth'

  # The vendored static xcframework (.a) is linked INTO the dynamic
  # peat_flutter.framework at this pod's link step. Release builds enable
  # dead-code stripping, which drops the C FFI symbols (ffi_peat_*,
  # uniffi_ffibuffer_*) because nothing in Swift/ObjC references them —
  # they're only resolved at runtime via DynamicLibrary.process().
  #
  # Fix on the POD target (not the app target): -all_load force-links every
  # symbol from the static archive into the framework, and DEAD_CODE_STRIPPING
  # = NO keeps the linker from pruning them afterward. This must be on
  # pod_target_xcconfig because that's where the .a → framework link happens.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => '-lc++ -lresolv -all_load',
    'DEAD_CODE_STRIPPING' => 'NO',
  }
end
