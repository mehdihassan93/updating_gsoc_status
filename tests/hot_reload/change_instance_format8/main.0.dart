// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:expect/expect.dart';
import 'package:reload_test/reload_test_utils.dart';

// Adapted from:
// https://github.com/dart-lang/sdk/blob/1a486499bf73ee5b007abbe522b94869a1f36d02/runtime/vm/isolate_reload_test.cc#L4071

// Regression for handle sharing bug: Change the shape of two classes and see
// that their instances don't change class.

class A {
  var x;
}

class B {
  var x, y, z, w;
}

var a, b;

Future<void> main() async {
  a = A();
  b = B();
  Expect.type<A>(a);
  Expect.type<B>(b);
  await hotReload();

  Expect.type<A>(a);
  Expect.type<B>(b);
}
