// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.


// @dart = 2.9
library fileapi;

import 'dart:html';

import 'package:async_helper/async_minitest.dart';

main() {
  test('requestFileSystem', () async {
    var expectation = FileSystem.supported ? returnsNormally : throws;
    expect(() async {
      await window.requestFileSystem(100);
    }, expectation);
  });
}
