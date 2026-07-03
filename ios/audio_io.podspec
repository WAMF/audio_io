#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint audio_io.podspec' to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'audio_io'
  s.version          = '0.0.1'
  s.summary          = 'A new flutter plugin project.'
  s.description      = <<-DESC
A new flutter plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  # Sources live under the Swift Package layout so the plugin builds with both
  # CocoaPods and Swift Package Manager. See ios/audio_io/Package.swift.
  s.source_files = 'audio_io/Sources/audio_io/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
