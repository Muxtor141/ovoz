#
# CocoaPods build of the ovoz engine. Swift Package Manager builds the same
# sources through ovoz/Package.swift.
#
Pod::Spec.new do |s|
  s.name             = 'ovoz'
  s.version          = '0.0.1'
  s.summary          = 'Native audio engine for Flutter: players, playlists, encrypted sources, audio session and lock-screen controls.'
  s.homepage         = 'https://github.com/Muxtor141/ovoz'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'Muxtor141'
  s.source           = { :path => '.' }
  # Swift engine + the Objective-C trampolines ffigen generates for Dart
  # callbacks (OvozBindings.g.m). The trampolines import the committed header in
  # headers/, which declares the Swift classes to Objective-C.
  s.source_files     = 'ovoz/Sources/ovoz/**/*.swift', 'ovoz/Sources/ovoz_ffi/*.m'
  s.public_header_files = []
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.frameworks = 'AVFoundation', 'MediaPlayer'
  s.requires_arc = true

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
  s.resource_bundles = {'ovoz_privacy' => ['ovoz/Sources/ovoz/PrivacyInfo.xcprivacy']}
end
