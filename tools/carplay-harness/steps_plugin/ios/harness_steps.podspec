# CarPlay harness only (tools/carplay-harness): never a part of the app.
Pod::Spec.new do |s|
  s.name             = 'harness_steps'
  s.version          = '0.0.1'
  s.summary          = 'Lets the CarPlay harness job steer the harness app in the Simulator.'
  s.description      = 'Lets the CarPlay harness job on the Mac steer the harness app in the Simulator. Never a part of the app.'
  s.homepage         = 'https://example.org'
  s.license          = { :type => 'As the repository', :text => 'The licence of the repository this folder is in (LICENSE at its root).' }
  s.author           = { 'CarPlay harness' => 'nobody@example.org' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.frameworks       = 'CarPlay'
  s.platform         = :ios, '16.3'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
