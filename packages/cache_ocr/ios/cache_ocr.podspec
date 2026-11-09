#
# Text recognition on iPhone and iPad with Apple Vision (VNRecognizeTextRequest), on the device and offline. Vision is part of
# iOS: nothing is bundled or downloaded.
#
Pod::Spec.new do |s|
  s.name             = 'cache_ocr'
  s.version          = '0.0.1'
  s.summary          = 'Cache on-device text recognition (Apple Vision).'
  s.description      = <<-DESC
Reads the text of scanned PDF pages rendered to images, with Apple Vision.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'Happy Little LLC'

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.frameworks = 'Vision', 'ImageIO', 'CoreGraphics'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
