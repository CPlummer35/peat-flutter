#
# Run `pod lib lint peat_flutter.podspec` to validate before publishing.
# Run `just build-macos` (or macos/build-rust.sh) to produce
# macos/Frameworks/libpeat_ffi.dylib before running `pod install`.
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
  s.platform         = :osx, '12.0'

  # Pre-built universal dylib (lipo of aarch64-apple-darwin + x86_64-apple-darwin).
  # Produced by macos/build-rust.sh.
  s.vendored_libraries = 'Frameworks/libpeat_ffi.dylib'

  s.dependency 'FlutterMacOS'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
