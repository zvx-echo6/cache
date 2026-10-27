#
# Native build for iPhone: the Rust search core and Kiwix's libzim (Xapian, ICU data), built by ios/build-core.sh into
# ios/native/libcache_search.a, libCoreKiwix.a and libcache_valhalla.a (run before `pod install`; CI does). All are linked into
# the app and the C ABI is found with DynamicLibrary.process() (lib/src/native.dart). ICU data is inside libCoreKiwix.a, so no
# ICU_DATA is needed on iPhone.
#
Pod::Spec.new do |s|
  s.name             = 'cache_search'
  s.version          = '0.0.1'
  s.summary          = 'Cache search core: the Rust search engine behind a small C ABI.'
  s.description      = <<-DESC
The Cache search core (ZIMs and libraries, places, live data, navigation) called from Dart over FFI.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'Happy Little LLC'

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '16.3'

  s.vendored_libraries = 'native/libcache_search.a', 'native/libCoreKiwix.a', 'native/libcache_valhalla.a'
  s.frameworks = 'Security', 'CoreFoundation', 'SystemConfiguration', 'Foundation'
  s.libraries = 'c++', 'resolv', 'iconv', 'z'

  # -force_load keeps every cs_* function of the core (nothing in the app calls them directly; Dart looks them up). libCoreKiwix.a is
  # not force-loaded: only the libzim parts the core uses are pulled from it.
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -force_load "${PODS_ROOT}/../.symlinks/plugins/cache_search/ios/native/libcache_search.a" -Wl,-u,_cache_free_bytes_on_disk',
  }
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
