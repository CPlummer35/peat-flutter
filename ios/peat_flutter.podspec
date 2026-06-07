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

  # Pre-built xcframework containing:
  #   aarch64-apple-ios          (device)
  #   lipo(aarch64-apple-ios-sim + x86_64-apple-ios)  (simulator)
  # Produced by ios/build-rust.sh.
  s.vendored_frameworks = 'Frameworks/PeatFFI.xcframework'

  s.dependency 'Flutter'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
