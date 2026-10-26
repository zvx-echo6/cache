#
# Native build for iPhone: llama.cpp with Metal and the Cache chat engine, built by ios/build-native.sh into
# ios/native/libcache_llama_all.a (run it before `pod install`; the CI workflow does). The library is linked into the
# app and its C ABI is found with DynamicLibrary.process().
#
Pod::Spec.new do |s|
  s.name             = 'cache_llama'
  s.version          = '0.0.1'
  s.summary          = 'Cache native LLM layer: llama.cpp and its chat engine.'
  s.description      = <<-DESC
llama.cpp (Metal) and the Cache chat engine behind a small C ABI, called from Dart over FFI.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'Happy Little LLC'

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '16.0'

  s.vendored_libraries = 'native/libcache_llama_all.a'
  s.frameworks = 'Metal', 'MetalKit', 'Foundation', 'Accelerate'
  s.libraries = 'c++'

  # -force_load keeps every cl_* function of the library (nothing in the app calls them directly; Dart looks them up).
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -force_load "${PODS_ROOT}/../.symlinks/plugins/cache_llama/ios/native/libcache_llama_all.a"',
  }
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
