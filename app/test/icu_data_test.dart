import 'dart:io';

import 'package:cache/search/icu_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root, lib, support;
  setUp(() {
    root = Directory.systemTemp.createTempSync('icu');
    lib = Directory('${root.path}/lib')..createSync();
    support = Directory('${root.path}/support')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('the data file is copied to app storage once, and ICU_DATA names its folder', () async {
    File('${lib.path}/$kIcuDataLibraryName').writeAsBytesSync(List.filled(1000, 7));
    final env = <String, String>{};
    final folder = await installIcuData(supportDir: support, libDir: lib.path, setEnv: (n, v) => env[n] = v);
    expect(folder, '${support.path}/icu');
    expect(env, {'ICU_DATA': folder});
    final dest = File('$folder/$kIcuDataFile');
    expect(dest.lengthSync(), 1000);
    expect(File('${dest.path}.part').existsSync(), isFalse);
    // A second start copies nothing (the file is the right size) but still sets the variable.
    dest.setLastModifiedSync(DateTime(2020));
    await installIcuData(supportDir: support, libDir: lib.path, setEnv: (n, v) => env[n] = v);
    expect(dest.lastModifiedSync(), DateTime(2020));
    // A file of another size is replaced (an app update with new data).
    File('${lib.path}/$kIcuDataLibraryName').writeAsBytesSync(List.filled(1200, 7));
    await installIcuData(supportDir: support, libDir: lib.path, setEnv: (n, v) => env[n] = v);
    expect(dest.lengthSync(), 1200);
  });

  test('a build without the data (no libzim in it) changes nothing', () async {
    final env = <String, String>{};
    expect(await installIcuData(supportDir: support, libDir: lib.path, setEnv: (n, v) => env[n] = v), isNull);
    expect(env, isEmpty);
    expect(Directory('${support.path}/icu').existsSync(), isFalse);
    expect(await installIcuData(supportDir: support, libDir: null, setEnv: (n, v) => env[n] = v), isNull);
  });
}
