// Copyright (c) 2023, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io' show Directory, File;

import 'package:_fe_analyzer_shared/src/util/options.dart';
import 'package:front_end/src/api_prototype/experimental_flags.dart'
    show
        AllowedExperimentalFlags,
        ExperimentalFlag,
        defaultAllowedExperimentalFlags;
import 'package:kernel/ast.dart' show Component, Version;
import 'package:testing/testing.dart' show TestDescription;

const Option<bool> fixNnbdReleaseVersion =
    const Option('--fix-nnbd-release-version', const BoolValue(false));

const Option<Uri?> dynamicInterface =
    const Option('--dynamic-interface', const UriValue());

const List<Option> testOptionsSpecification = [
  fixNnbdReleaseVersion,
  dynamicInterface,
];

class SuiteTestOptions {
  final Map<Uri, TestOptions> _testOptions = {};

  /// Computes the test for [description].
  TestOptions computeTestOptions(TestDescription description) {
    Directory directory = new File.fromUri(description.uri).parent;
    TestOptions? testOptions = _testOptions[directory.uri];
    if (testOptions == null) {
      File optionsFile =
          new File.fromUri(directory.uri.resolve('test.options'));
      Set<Uri> linkDependencies = new Set<Uri>();
      AllowedExperimentalFlags? allowedExperimentalFlags;
      Map<ExperimentalFlag, Version>? experimentEnabledVersion;
      Map<ExperimentalFlag, Version>? experimentReleasedVersion;
      Uri? dynamicInterfaceSpecificationUri;
      if (optionsFile.existsSync()) {
        List<String> arguments =
            ParsedOptions.readOptionsFile(optionsFile.readAsStringSync());
        ParsedOptions parsedOptions =
            ParsedOptions.parse(arguments, testOptionsSpecification);
        if (fixNnbdReleaseVersion.read(parsedOptions)) {
          // Allow package:allowed_package to use nnbd features from version
          // 2.9.
          allowedExperimentalFlags = new AllowedExperimentalFlags(
              sdkDefaultExperiments:
                  defaultAllowedExperimentalFlags.sdkDefaultExperiments,
              sdkLibraryExperiments:
                  defaultAllowedExperimentalFlags.sdkLibraryExperiments,
              packageExperiments: {
                ...defaultAllowedExperimentalFlags.packageExperiments,
                'allowed_package': {ExperimentalFlag.nonNullable}
              });
          experimentEnabledVersion = const {
            ExperimentalFlag.nonNullable: const Version(2, 10)
          };
          experimentReleasedVersion = const {
            ExperimentalFlag.nonNullable: const Version(2, 9)
          };
        }
        dynamicInterfaceSpecificationUri = dynamicInterface.read(parsedOptions);
        for (String argument in parsedOptions.arguments) {
          Uri uri = description.uri.resolve(argument);
          if (!uri.isScheme('package')) {
            File f = new File.fromUri(uri);
            if (!f.existsSync()) {
              throw new UnsupportedError("No file found: $f ($argument)");
            }
            uri = f.uri;
          }
          linkDependencies.add(uri);
        }
      }
      testOptions = new TestOptions(linkDependencies,
          allowedExperimentalFlags: allowedExperimentalFlags,
          experimentEnabledVersion: experimentEnabledVersion,
          experimentReleasedVersion: experimentReleasedVersion,
          dynamicInterfaceSpecificationUri: dynamicInterfaceSpecificationUri);
      _testOptions[directory.uri] = testOptions;
    }
    return testOptions;
  }
}

/// Options for a single test located within its own subfolder.
///
/// This is used for instance for defining custom link dependencies and
/// setting up custom experimental flag defaults for a single test.
class TestOptions {
  final Set<Uri> linkDependencies;
  final AllowedExperimentalFlags? allowedExperimentalFlags;
  final Map<ExperimentalFlag, Version>? experimentEnabledVersion;
  final Map<ExperimentalFlag, Version>? experimentReleasedVersion;
  final Uri? dynamicInterfaceSpecificationUri;
  Component? component;
  List<Iterable<String>>? errors;

  TestOptions(this.linkDependencies,
      {required this.allowedExperimentalFlags,
      required this.experimentEnabledVersion,
      required this.experimentReleasedVersion,
      required this.dynamicInterfaceSpecificationUri});
}
