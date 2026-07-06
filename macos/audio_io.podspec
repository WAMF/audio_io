#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint audio_io.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'audio_io'
  s.version          = '0.1.9'
  s.summary          = 'Very simple interface to provide a stream of audio data for processing/visualising in Flutter'
  s.description      = <<-DESC
Very simple interface to provide a stream of audio data for processing/visualising in Flutter
                       DESC
  s.homepage         = 'https://www.wearemobilefirst.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Mobile First' => 'hello@wearemobilefirst.com' }

  s.source           = { :path => '.' }
  # Sources live under the Swift Package layout so the plugin builds with both
  # CocoaPods and Swift Package Manager. See macos/audio_io/Package.swift.
  s.source_files     = 'audio_io/Sources/audio_io/**/*.swift'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.15'
  s.swift_version = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
