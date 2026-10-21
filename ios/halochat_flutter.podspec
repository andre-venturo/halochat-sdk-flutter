Pod::Spec.new do |s|
  s.name             = 'halochat_flutter'
  s.version          = '0.1.0'
  s.summary          = 'Flutter bridge over the HaloChat core SDK (no built-in UI).'
  s.description      = <<-DESC
Flutter bridge over the HaloChat core SDK: timeline stream, history, send, attachments, push.
                       DESC
  s.homepage         = 'https://github.com/andre-venturo/halochat-sdk-flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Venturo' => 'dev@venturo.id' }
  s.source           = { :path => '.' }
  s.source_files = 'halochat_flutter/Sources/halochat_flutter/**/*.swift'
  s.dependency 'Flutter'
  # HaloChat is not on CocoaPods trunk yet: the app Podfile must declare
  #   pod 'HaloChat', :git => 'https://github.com/afgventura/halochat-ios.git', :tag => '0.3.0'
  # 'HaloChat' resolves to the Core subspec only.
  s.dependency 'HaloChat', '~> 0.3.0'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
end
