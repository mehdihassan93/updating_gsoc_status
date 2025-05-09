// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async' show Future, StreamSubscription;
import 'dart:convert' show JsonEncoder, jsonDecode, utf8;
import 'dart:io' show File, stdin, stdout;
import 'dart:math' show max;
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:_fe_analyzer_shared/src/parser/parser.dart'
    show Listener, Parser;
import 'package:_fe_analyzer_shared/src/scanner/scanner.dart'
    show ErrorToken, ScannerConfiguration, Token;
import 'package:_fe_analyzer_shared/src/util/relativize.dart'
    show relativizeUri, isWindows;
import 'package:compiler/src/kernel/dart2js_target.dart' show Dart2jsTarget;
import 'package:dev_compiler/src/kernel/target.dart' show DevCompilerTarget;
import 'package:front_end/src/api_prototype/compiler_options.dart'
    show CompilerOptions, DiagnosticMessage;
import 'package:front_end/src/api_prototype/experimental_flags.dart'
    show ExperimentalFlag;
import 'package:front_end/src/api_prototype/file_system.dart'
    show FileSystem, FileSystemEntity, FileSystemException;
import 'package:front_end/src/api_prototype/incremental_kernel_generator.dart'
    show IncrementalCompilerResult;
import 'package:front_end/src/base/compiler_context.dart' show CompilerContext;
import 'package:front_end/src/base/incremental_compiler.dart'
    show IncrementalCompiler, IncrementalKernelTarget;
import 'package:front_end/src/base/messages.dart' show Message;
import 'package:front_end/src/base/processed_options.dart'
    show ProcessedOptions;
import 'package:front_end/src/builder/library_builder.dart';
import 'package:front_end/src/kernel/utils.dart' show ByteSink;
import 'package:front_end/src/source/diet_parser.dart'
    show useImplicitCreationExpressionInCfe;
import 'package:front_end/src/util/parser_ast.dart';
import 'package:front_end/src/util/parser_ast_helper.dart';
import 'package:front_end/src/util/textual_outline.dart' show textualOutline;
import 'package:kernel/ast.dart'
    show Component, LibraryPart, Version, defaultLanguageVersion;
import 'package:kernel/binary/ast_to_binary.dart' show BinaryPrinter;
import 'package:kernel/target/targets.dart' show Target, TargetFlags;
import 'package:package_config/package_config.dart';
import "package:vm/modular/target/flutter.dart" show FlutterTarget;
import "package:vm/modular/target/vm.dart" show VmTarget;

import 'incremental_suite.dart' show getOptions;
import 'parser_suite.dart' as parser_suite;
import 'parser_test_listener.dart' show ParserTestListener;

class TestMinimizerSettings {
  final _FakeFileSystem _fsInitial = new _FakeFileSystem();
  final _FakeFileSystem _fsNotInitial = new _FakeFileSystem();
  _FakeFileSystem get _fs {
    if (_useInitialFs) return _fsInitial;
    return _fsNotInitial;
  }

  bool _useInitialFs = true;
  final List<Uri> entryUris = [];
  Uri? platformUri;
  Uri? packagesFileUri;
  bool noPlatform = false;
  bool initialOnlyOutline = false;
  bool loadFromComponentBeforeInvalidate = false;
  bool invalidateAllAtOnce = false;
  bool experimentalInvalidation = false;
  bool serialize = false;
  bool widgetTransformation = false;
  final List<Uri> invalidate = [];
  String targetString = "vm";
  bool noTryToDeleteEmptyFilesUpFront = false;
  bool oldBlockDelete = false;
  bool lineDelete = false;
  bool byteDelete = false;
  bool askAboutRedirectCrashTarget = false;
  bool autoUncoverAllCrashes = false;
  int stackTraceMatches = 1;
  String? lookForErrorErrorOnReload;
  final Set<String> askedAboutRedirect = {};
  final List<Map<String, dynamic>> fileSystems = [];
  final Set<String> allAutoRedirects = {};

  void goToFileSystem(int i) {
    Map<String, dynamic> fileSystem = fileSystems[i];
    fileSystems[i] = _fsNotInitial.toJson();
    _fsNotInitial.initializeFromJson(fileSystem);
  }

  Map<String, dynamic> toJson() {
    List<Map<String, dynamic>> fileSystems =
        new List<Map<String, dynamic>>.from(this.fileSystems);
    fileSystems.add(_fsNotInitial.toJson());
    return {
      'entryUris': entryUris.map((uri) => uri.toString()).toList(),
      'platformUri': platformUri.toString(),
      'packagesFileUri': packagesFileUri.toString(),
      'noPlatform': noPlatform,
      'loadFromComponentBeforeInvalidate': loadFromComponentBeforeInvalidate,
      'invalidateAllAtOnce': invalidateAllAtOnce,
      'initialOnlyOutline': initialOnlyOutline,
      'experimentalInvalidation': experimentalInvalidation,
      'serialize': serialize,
      'widgetTransformation': widgetTransformation,
      'invalidate': invalidate.map((uri) => uri.toString()).toList(),
      'targetString': targetString,
      'noTryToDeleteEmptyFilesUpFront': noTryToDeleteEmptyFilesUpFront,
      'oldBlockDelete': oldBlockDelete,
      'lineDelete': lineDelete,
      'byteDelete': byteDelete,
      'askAboutRedirectCrashTarget': askAboutRedirectCrashTarget,
      'autoUncoverAllCrashes': autoUncoverAllCrashes,
      'stackTraceMatches': stackTraceMatches,
      'askedAboutRedirect': askedAboutRedirect.toList(),
      'fileSystems': fileSystems,
      'allAutoRedirects': allAutoRedirects.toList(),
      'lookForErrorErrorOnReload': lookForErrorErrorOnReload,
    };
  }

  void initializeFromJson(Map<String, dynamic> json) {
    entryUris.clear();
    entryUris.addAll(
        (json["entryUris"] as List).map((uriString) => Uri.parse(uriString)));
    platformUri = Uri.parse(json["platformUri"]);
    packagesFileUri = Uri.parse(json["packagesFileUri"]);
    noPlatform = json["noPlatform"];
    loadFromComponentBeforeInvalidate =
        json["loadFromComponentBeforeInvalidate"];
    invalidateAllAtOnce = json["invalidateAllAtOnce"];
    initialOnlyOutline = json["initialOnlyOutline"];
    experimentalInvalidation = json["experimentalInvalidation"];
    serialize = json["serialize"];
    widgetTransformation = json["widgetTransformation"];
    invalidate.clear();
    invalidate.addAll(
        (json["invalidate"] as List).map((uriString) => Uri.parse(uriString)));
    targetString = json["targetString"];
    noTryToDeleteEmptyFilesUpFront = json["noTryToDeleteEmptyFilesUpFront"];
    oldBlockDelete = json["oldBlockDelete"];
    lineDelete = json["lineDelete"];
    byteDelete = json["byteDelete"];
    askAboutRedirectCrashTarget = json["askAboutRedirectCrashTarget"];
    autoUncoverAllCrashes = json["autoUncoverAllCrashes"];
    stackTraceMatches = json["stackTraceMatches"];
    askedAboutRedirect.clear();
    askedAboutRedirect.addAll((json["askedAboutRedirect"] as List).cast());
    fileSystems.clear();
    fileSystems.addAll((json["fileSystems"] as List).cast());
    allAutoRedirects.clear();
    allAutoRedirects.addAll((json["allAutoRedirects"] as List).cast());
    lookForErrorErrorOnReload = json["lookForErrorErrorOnReload"];

    _fsNotInitial.initializeFromJson(fileSystems.removeLast());
  }
}

// TODO(jensj): The different cuts and inlines in this file aren't tested.
// The probably should be. So they should probably be factored out so they can
// be tested and then tested.
// Similarly the whole +/- 1 thing to cut out what we want is weird and should
// be factored out into helpers too, or we should have some sort of visitor
// that can include the "real" numbers (which should then also be tested).

class TestMinimizer {
  final TestMinimizerSettings _settings;
  _FakeFileSystem get _fs => _settings._fs;
  List<Uri> get _entryUris => _settings.entryUris;
  String? _expectedCrashLine;
  bool _quit = false;
  bool _skip = false;
  bool _check = false;
  int _currentFsNum = -1;
  bool _gotWantedError = false;

  Component? _latestComponent;
  IncrementalCompiler? _latestCrashingIncrementalCompiler;
  Map<Uri, LibraryBuilder>? _latestCrashingKnownInitialBuilders;
  IncrementalKernelTarget? _latestKernelTarget;
  StreamSubscription<List<int>>? _stdinSubscription;

  static const int _$LF = 10;

  TestMinimizer(this._settings);

  bool? _oldEchoMode;
  bool? _oldLineMode;

  Future<void> _resetStdin() async {
    try {
      stdin.echoMode = _oldEchoMode!;
    } catch (e) {}
    try {
      stdin.lineMode = _oldLineMode!;
    } catch (e) {}
    await _stdinSubscription!.cancel();
  }

  void _setupStdin() {
    try {
      _oldEchoMode = stdin.echoMode;
      _oldLineMode = stdin.lineMode;
      stdin.echoMode = false;
      stdin.lineMode = false;
    } catch (e) {
      print("Trying to setup 'stdin' failed. Continuing anyway, "
          "but 'q', 'i' etc might not work.");
    }
    _stdinSubscription = stdin.listen((List<int> event) {
      if (event.length == 1 && event.single == "q".codeUnits.single) {
        print("\n\nGot told to quit!\n\n");
        _quit = true;
      } else if (event.length == 1 && event.single == "s".codeUnits.single) {
        print("\n\nGot told to skip!\n\n");
        _skip = true;
      } else if (event.length == 1 && event.single == "c".codeUnits.single) {
        print("\n\nGot told to check!\n\n");
        _check = true;
      } else if (event.length == 1 && event.single == "i".codeUnits.single) {
        print("\n\n--- STATUS INFORMATION START ---\n\n");
        print("Currently looking for this crash: $_expectedCrashLine\n\n");
        print("Currently on filesystem #$_currentFsNum out of "
            "${_settings.fileSystems.length}\n\n");

        int totalFiles = 0;
        int emptyFiles = 0;
        int combinedSize = 0;
        for (Uri? uri in _fs.data.keys) {
          final Uint8List? originalBytes = _fs.data[uri];
          if (originalBytes == null) continue;
          totalFiles++;
          if (originalBytes.isEmpty) emptyFiles++;
          combinedSize += originalBytes.length;
        }
        print("Total files left: $totalFiles.");
        print("Of which empty: $emptyFiles.");
        print("Combined size left: $combinedSize bytes.");
        print("\n\n--- STATUS INFORMATION END ---\n\n");
      } else {
        print("\n\nGot stdin input: $event\n\n");
      }
    });
  }

  Future tryToMinimize() async {
    _setupStdin();
    try {
      while (_currentFsNum < _settings.fileSystems.length) {
        try {
          if (_currentFsNum >= 0) {
            print("Replacing filesystem!");
            _settings.goToFileSystem(_currentFsNum);
            _expectedCrashLine = null;
            _latestComponent = null;
            _latestCrashingIncrementalCompiler = null;
            _latestCrashingKnownInitialBuilders = null;
          }
          await _tryToMinimizeImpl();
          if (_currentFsNum + 1 < _settings.fileSystems.length) {
            // We have more to do --- but we just printed something the user
            // might want to read. So wait a little before continuing.
            print("Waiting for 5 seconds before continuing.");
            await Future.delayed(new Duration(seconds: 5));
          }
        } catch (e) {
          if (e is _DoesntCrashOnInput) {
            print(
                "Currently doesn't crash (or no longer crashes) the compiler.");
          } else {
            print(
                "About to crash. Dumping settings including the filesystem so "
                "we can (hopefully) continue later.");
            _dumpToJson();
            rethrow;
          }
        }
        _currentFsNum++;
      }
    } finally {
      await _resetStdin();
    }
  }

  Future _tryToMinimizeImpl() async {
    // Set main to be basically empty up front.
    _settings._useInitialFs = true;
    for (Uri entry in _entryUris) {
      _fs.data[entry] = utf8.encode("main() {}");
    }
    Component initialComponent = await _getInitialComponent();
    print("Compiled initially (without data)");
    // Remove fake cache.
    for (Uri entry in _entryUris) {
      _fs.data.remove(entry);
    }

    _settings._useInitialFs = false;

    // First assure it actually crash on the input.
    if (!await _crashesOnCompile(initialComponent)) {
      throw new _DoesntCrashOnInput();
    }
    print("Step #1: We did crash on the input!");

    // All file should now be cached.
    _fs._redirectAndRecord = false;

    // For all dart files: Parse them as set their source as the parsed source
    // to "get around" any encoding issues when printing later.
    Map<Uri?, Uint8List?> copy = new Map.of(_fs.data);
    for (Uri? uri in _fs.data.keys) {
      if (await _shouldQuit()) break;
      String uriString = uri.toString();
      if (uriString.endsWith(".json") ||
          uriString.endsWith(".packages") ||
          uriString.endsWith(".dill") ||
          _fs.data[uri] == null ||
          _fs.data[uri]!.isEmpty) {
        // skip
      } else {
        try {
          if (_knownByCompiler(uri!)) {
            String parsedString = _getFileAsStringContent(_fs.data[uri]!);
            _fs.data[uri] = utf8.encode(parsedString);
          }
        } catch (e) {
          // crash in scanner/parser --- keep original file. This crash might
          // be what we're looking for!
        }
      }
    }
    if (!await _crashesOnCompile(initialComponent)) {
      // Now - for whatever reason - we didn't crash. Restore.
      _fs.data.clear();
      _fs.data.addAll(copy);
    }

    // Operate on one file at a time: Try to delete all content in file.
    List<Uri> uris = new List<Uri>.from(_fs.data.keys);

    // TODO(jensj): Can we "thread" this?
    bool changedSome = true;
    while (changedSome) {
      if (await _shouldQuit()) break;
      while (changedSome) {
        if (await _shouldQuit()) break;
        changedSome = false;
        for (int i = 0; i < uris.length; i++) {
          if (await _shouldQuit()) break;
          Uri uri = uris[i];
          if (_fs.data[uri] == null || _fs.data[uri]!.isEmpty) continue;
          print("About to work on file $i of ${uris.length}");
          await _deleteContent(uris, i, false, initialComponent);
          if (_fs.data[uri] == null || _fs.data[uri]!.isEmpty) {
            changedSome = true;
          }
        }
      }

      // Try to delete empty files.
      if (!_settings.noTryToDeleteEmptyFilesUpFront) {
        bool changedSome2 = true;
        while (changedSome2) {
          if (await _shouldQuit()) break;
          changedSome2 = false;
          for (int i = 0; i < uris.length; i++) {
            if (await _shouldQuit()) break;
            Uri uri = uris[i];
            if (_fs.data[uri] == null || _fs.data[uri]!.isNotEmpty) continue;
            print("About to work on file $i of ${uris.length}");
            await _deleteContent(uris, i, false, initialComponent,
                deleteFile: true);
            if (_fs.data[uri] == null) {
              changedSome = true;
              changedSome2 = true;
            }
          }
        }
      }

      int left = 0;
      for (Uri uri in uris) {
        if (_fs.data[uri] == null || _fs.data[uri]!.isEmpty) continue;
        left++;
      }
      print("There's now $left files of ${_fs.data.length} files left");

      // Operate on one file at a time.
      for (Uri? uri in _fs.data.keys) {
        if (_fs.data[uri] == null || _fs.data[uri]!.isEmpty) continue;
        if (await _shouldQuit()) break;

        if (await _tryRemoveIfNotKnownByCompiler(uri, initialComponent)) {
          if (_fs.data[uri] == null || _fs.data[uri]!.isEmpty) continue;
          if (await _shouldQuit()) break;
        }

        if (_check) {
          _check = false;
          if (!await _crashesOnCompile(initialComponent)) {
            throw "Check revealed that the current file system doesn't crash.";
          } else {
            print("Check OK!");
          }
        }

        print("Now working on $uri");

        int prevLength = _fs.data[uri]!.length;

        await _deleteBlocks(uri!, initialComponent);
        await _deleteEmptyLines(uri, initialComponent);

        if (_settings.oldBlockDelete) {
          // Try to delete blocks.
          await _deleteBlocksOld(uri, initialComponent);
        }

        if (_settings.lineDelete) {
          // Try to delete lines.
          await _deleteLines(uri, initialComponent);
        }

        print("We're now at ${_fs.data[uri]!.length} bytes for $uri "
            "(was $prevLength).");
        if (prevLength != _fs.data[uri]!.length) changedSome = true;
        if (_fs.data[uri]!.isEmpty) continue;

        if (_settings.byteDelete) {
          // Now try to delete 'arbitrarily' (for any given start offset do an
          // exponential binary search).
          int prevLength = _fs.data[uri]!.length;
          while (true) {
            if (await _shouldQuit()) break;
            await _binarySearchDeleteData(uri, initialComponent);

            if (_fs.data[uri]!.length == prevLength) {
              // No progress.
              break;
            } else {
              print("We're now at ${_fs.data[uri]!.length} bytes");
              prevLength = _fs.data[uri]!.length;
              changedSome = true;
            }
          }
        }
      }
      for (Uri? uri in _fs.data.keys) {
        if (_fs.data[uri] == null || _fs.data[uri]!.isEmpty) continue;
        if (await _shouldQuit()) break;

        if (await _tryRemoveIfNotKnownByCompiler(uri, initialComponent)) {
          if (_fs.data[uri] == null || _fs.data[uri]!.isEmpty) continue;
          if (await _shouldQuit()) break;
        }

        if (await _attemptInline(uri!, initialComponent)) {
          changedSome = true;

          if (await _tryRemoveIfNotKnownByCompiler(uri, initialComponent)) {
            if (_fs.data[uri] == null || _fs.data[uri]!.isEmpty) continue;
            if (await _shouldQuit()) break;
          }
        }
      }

      // Partially a sanity-check, and partially to make sure there's a latest
      // component for [_tryToRemoveUnreferencedFileContent] to work with (if
      // crashing after an invalidation).
      if (!await _crashesOnCompile(initialComponent)) {
        throw "At a state where we should crash, we didn't!";
      }
      await _tryToRemoveUnreferencedFileContent(initialComponent,
          deleteFile: true);
    }

    if (await _shouldQuit()) {
      print("\n\nASKED TO QUIT\n\n");
    } else {
      print("\n\nDONE\n\n");
    }

    Uri jsonOut = _dumpToJson();

    if (!await _shouldQuit()) {
      // Test converting to incremental compiler yaml test.
      _outputIncrementalCompilerYamlTest();
      print("\n\n\n");

      for (Uri uri in uris) {
        if (_fs.data[uri] == null || _fs.data[uri]!.isEmpty) continue;
        if (uri.path.endsWith(".dill")) continue;
        print("Uri $uri has this content:");

        try {
          String utfDecoded = utf8.decode(_fs.data[uri]!, allowMalformed: true);
          print(utfDecoded);
        } catch (e) {
          print(_fs.data[uri]);
          print("(which crashes when trying to decode as utf8)");
        }
        print("\n\n====================\n\n");
      }

      print("Wrote json dump to $jsonOut");
    }
  }

  Future<bool> _shouldQuit() async {
    // allow some time for stdin.listen to process data.
    await new Future.delayed(new Duration(milliseconds: 5));
    return _quit;
  }

  Uri _dumpToJson() {
    JsonEncoder jsonEncoder = new JsonEncoder.withIndent("  ");
    String json = jsonEncoder.convert(_settings);
    int i = 0;
    Uri? jsonOut;
    while (jsonOut == null || new File.fromUri(jsonOut).existsSync()) {
      jsonOut = Uri.base.resolve("crash_minimizer_result_$i");
      i++;
    }
    new File.fromUri(jsonOut).writeAsStringSync(json);
    print("Wrote json dump to $jsonOut");
    return jsonOut;
  }

  /// Attempts to inline small files in other files.
  /// Returns true if anything was changed, i.e. if at least one inlining was a
  /// success.
  Future<bool> _attemptInline(Uri uri, Component initialComponent) async {
    // Don't attempt to inline the main uri --- that's our entry!
    if (_entryUris.contains(uri)) return false;

    Uint8List inlineData = _fs.data[uri]!;
    bool hasMultipleLines = false;
    for (int i = 0; i < inlineData.length; i++) {
      if (inlineData[i] == _$LF) {
        hasMultipleLines = true;
        break;
      }
    }
    // TODO(jensj): Maybe inline slightly bigger files too?
    if (hasMultipleLines) {
      return false;
    }

    Uri inlinableUri = uri;

    int compileTry = 0;
    bool changed = false;

    for (Uri? uri in _fs.data.keys) {
      if (!uri.toString().endsWith(".dart")) continue;
      if (inlinableUri == uri) continue;
      final Uint8List? originalBytes = _fs.data[uri];
      if (uri == null || originalBytes == null || originalBytes.isEmpty) {
        continue;
      }
      CompilationUnitEnd ast =
          getAST(originalBytes, includeBody: false, includeComments: false);
      // Find all imports/exports of this file (if any).
      // If finding any:
      // * remove all of them, then
      // * find the end of the last import/export, and
      // * insert the content of the file there.
      // * if that *doesn't* work and we've inserted an export,
      //   try converting that to an import instead.
      List<_Replacement> replacements = [];
      for (ImportEnd import in ast.getImports()) {
        Token importUriToken = import.importKeyword.next!;
        Uri importUri = _getUri(importUriToken, uri);
        if (inlinableUri == importUri) {
          replacements.add(new _Replacement(
              import.importKeyword.offset - 1, import.semicolon!.offset + 1));
        }
      }
      for (ExportEnd export in ast.getExports()) {
        Token exportUriToken = export.exportKeyword.next!;
        Uri exportUri = _getUri(exportUriToken, uri);
        if (inlinableUri == exportUri) {
          replacements.add(new _Replacement(
              export.exportKeyword.offset - 1, export.semicolon.offset + 1));
        }
      }
      if (replacements.isEmpty) continue;

      // Step 1: Remove all imports/exports *of* this file (the inlinable file).
      final Uint8List withoutInlineable =
          _replaceRange(replacements, originalBytes);

      // Step 2: Find the last import/export.
      // TODO(jensj): This doesn't work if
      // * The file we're inlining into doesn't have any imports/exports but do
      //   have a `library` declaration.
      // * The file we're inlining has a library declaration.
      int offsetOfLast = 0;
      ast =
          getAST(withoutInlineable, includeBody: false, includeComments: false);
      for (ImportEnd import in ast.getImports()) {
        offsetOfLast = max(offsetOfLast, import.semicolon!.offset + 1);
      }
      for (ExportEnd export in ast.getExports()) {
        offsetOfLast = max(offsetOfLast, export.semicolon.offset + 1);
      }

      // Step 3: Insert the content of the file there. Note, though,
      // that any imports/exports in _that_ file should be changed to be valid
      // in regards to the new placement.
      final String withoutInlineableString = utf8.decode(withoutInlineable);
      StringBuffer builder = new StringBuffer();
      for (int i = 0; i < offsetOfLast; i++) {
        builder.writeCharCode(withoutInlineableString.codeUnitAt(i));
      }
      builder.write("\n");
      builder.write(utf8
          .decode(_rewriteImportsExportsToUri(inlineData, uri, inlinableUri)));
      builder.write("\n");
      for (int i = offsetOfLast; i < withoutInlineableString.length; i++) {
        builder.writeCharCode(withoutInlineableString.codeUnitAt(i));
      }
      final Uint8List inlinedWithoutChange = utf8.encode(builder.toString());

      if (!_parsesWithoutError(inlinedWithoutChange)) {
        print("WARNING: Parser error after stuff at ${StackTrace.current}");
      }

      // Step 4: Try it out.
      if (await _shouldQuit()) break;
      if (_skip) {
        _skip = false;
        break;
      }
      stdout.write(".");
      compileTry++;
      if (compileTry % 50 == 0) {
        stdout.write("(at $compileTry)\n");
      }
      _fs.data[uri] = inlinedWithoutChange;
      if (await _crashesOnCompile(initialComponent)) {
        print("Could inline $inlinableUri into $uri.");
        changed = true;
        // File was already updated.
      } else {
        // Couldn't replace that.
        // Insert the original again.
        _fs.data[uri] = originalBytes;

        // If we've inlined an export, try changing that to an import.
        builder = new StringBuffer();
        for (int i = 0; i < offsetOfLast; i++) {
          builder.writeCharCode(withoutInlineableString.codeUnitAt(i));
        }
        builder.write("\n");
        builder.write(utf8.decode(_rewriteImportsExportsToUri(
            inlineData, uri, inlinableUri,
            convertExportToImport: true)));
        builder.write("\n");
        for (int i = offsetOfLast; i < withoutInlineableString.length; i++) {
          builder.writeCharCode(withoutInlineableString.codeUnitAt(i));
        }
        Uint8List inlinedWithChange = utf8.encode(builder.toString());

        if (!_parsesWithoutError(inlinedWithChange)) {
          print("WARNING: Parser error after stuff at ${StackTrace.current}");
        }

        // Step 4: Try it out.
        if (await _shouldQuit()) break;
        if (_skip) {
          _skip = false;
          break;
        }
        stdout.write(".");
        compileTry++;
        if (compileTry % 50 == 0) {
          stdout.write("(at $compileTry)\n");
        }
        _fs.data[uri] = inlinedWithChange;
        if (await _crashesOnCompile(initialComponent)) {
          print("Could inline $inlinableUri into $uri "
              "(by converting export to import).");
          changed = true;
          // File was already updated.
        } else {
          // Couldn't replace that.
          // Insert the original again.
          _fs.data[uri] = originalBytes;
        }
      }
    }

    return changed;
  }

  Uint8List _rewriteImportsExportsToUri(
      Uint8List oldData, Uri newUri, Uri oldUri,
      {bool convertExportToImport = false}) {
    CompilationUnitEnd ast =
        getAST(oldData, includeBody: false, includeComments: false);
    List<_Replacement> replacements = [];
    for (ImportEnd import in ast.getImports()) {
      _rewriteImportsExportsToUriInternal(
          import.importKeyword.next!, oldUri, replacements, newUri);
    }
    for (ExportEnd export in ast.getExports()) {
      if (convertExportToImport) {
        replacements.add(new _Replacement(
          export.exportKeyword.offset - 1,
          export.exportKeyword.offset + export.exportKeyword.length,
          nullOrReplacement: "import",
        ));
      }
      _rewriteImportsExportsToUriInternal(
          export.exportKeyword.next!, oldUri, replacements, newUri);
    }
    if (replacements.isNotEmpty) {
      Uint8List candidate = _replaceRange(replacements, oldData);
      return candidate;
    }
    return oldData;
  }

  void _outputIncrementalCompilerYamlTest() {
    int dartFiles = 0;
    for (MapEntry<Uri?, Uint8List?> entry in _fs.data.entries) {
      if (entry.key!.pathSegments.last.endsWith(".dart")) {
        if (entry.value != null) dartFiles++;
      }
    }

    print("------ Reproduction as semi-done incremental yaml test file ------");

    // TODO(jensj): don't use full uris.
    print("""
# Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

# Reproduce a crash.

type: newworld""");
    if (_settings.widgetTransformation) {
      print("trackWidgetCreation: true");
      print("target: dartdevc # needed for widget creation to be run");
    }
    print("""
worlds:
  - entry:""");
    for (Uri entry in _settings.entryUris) {
      print("      - $entry");
    }
    if (_settings.experimentalInvalidation) {
      print("    experiments: alternative-invalidation-strategy");
    }
    print("    sources:");
    for (MapEntry<Uri?, Uint8List?> entry in _fs.data.entries) {
      if (entry.value == null) continue;
      if (entry.key == null) continue;
      if (entry.key!.path.endsWith(".dill")) continue;
      print("      ${entry.key}: |");
      String string = utf8.decode(entry.value!);
      List<String> lines = string.split("\n");
      for (String line in lines) {
        print("        $line");
      }
    }
    print("    expectedLibraryCount: $dartFiles "
        "# with parts this is not right");
    print("");

    if (_settings.invalidateAllAtOnce) {
      print("  - entry:");
      for (Uri entry in _settings.entryUris) {
        print("      - $entry");
      }
      if (_settings.experimentalInvalidation) {
        print("    experiments: alternative-invalidation-strategy");
      }
      print("    worldType: updated");
      print("    expectInitializeFromDill: false # or true?");
      print("    invalidate:");
      for (Uri uri in _settings.invalidate) {
        print("      - $uri");
      }
      print("    expectedLibraryCount: $dartFiles "
          "# with parts this is not right");
      print("    advancedInvalidation: bodiesOnly # or something else?");
      print("");
    } else {
      for (Uri uri in _settings.invalidate) {
        print("  - entry:");
        for (Uri entry in _settings.entryUris) {
          print("      - $entry");
        }
        if (_settings.experimentalInvalidation) {
          print("    experiments: alternative-invalidation-strategy");
        }
        print("    worldType: updated");
        print("    expectInitializeFromDill: false # or true?");
        print("    invalidate:");
        print("      - $uri");
        print("    expectedLibraryCount: $dartFiles "
            "# with parts this is not right");
        print("    advancedInvalidation: bodiesOnly # or something else?");
        print("");
      }
    }

    print("------------------------------------------------------------------");
  }

  void _rewriteImportsExportsToUriInternal(
      Token uriToken, Uri oldUri, List<_Replacement> replacements, Uri newUri) {
    Uri tokenUri = _getUri(uriToken, oldUri, resolvePackage: false);
    if (tokenUri.isScheme("package") || tokenUri.isScheme("dart")) return;
    Uri asPackageUri = _getImportUri(tokenUri);
    if (asPackageUri.isScheme("package")) {
      // Just replace with this package uri.
      replacements.add(new _Replacement(
        uriToken.offset - 1,
        uriToken.offset + uriToken.length,
        nullOrReplacement: '"${asPackageUri.toString()}"',
      ));
    } else {
      String relative = relativizeUri(newUri, tokenUri, isWindows);
      // TODO(jensj): Maybe if the relative uri becomes too long or has to many
      // "../../" etc we should just use the absolute uri instead.
      replacements.add(new _Replacement(
        uriToken.offset - 1,
        uriToken.offset + uriToken.length,
        nullOrReplacement: '"${relative}"',
      ));
    }
  }

  Uri _getUri(Token uriToken, Uri uri, {bool resolvePackage = true}) {
    String uriString = uriToken.lexeme;
    uriString = uriString.substring(1, uriString.length - 1);
    Uri uriTokenUri = uri.resolve(uriString);
    if (resolvePackage && uriTokenUri.isScheme("package")) {
      Package package = _latestCrashingIncrementalCompiler!
          .getPackageForPackageName(uriTokenUri.pathSegments.first)!;
      uriTokenUri = package.packageUriRoot
          .resolve(uriTokenUri.pathSegments.skip(1).join("/"));
    }
    return uriTokenUri;
  }

  Uri _getImportUri(Uri uri) {
    return _latestKernelTarget!.getEntryPointUri(uri);
  }

  Uint8List _sublist(Uint8List data, int start, int end) {
    Uint8List result = new Uint8List(end - start);
    result.setRange(0, result.length, data, start);
    return result;
  }

  Future<void> _binarySearchDeleteData(
      Uri uri, Component initialComponent) async {
    Uint8List latestCrashData = _fs.data[uri]!;
    int offset = 0;
    while (offset < latestCrashData.length) {
      print("Working at offset $offset of ${latestCrashData.length}");
      BytesBuilder builder = new BytesBuilder();
      builder.add(_sublist(latestCrashData, 0, offset));
      builder
          .add(_sublist(latestCrashData, offset + 1, latestCrashData.length));
      Uint8List candidate = builder.takeBytes();
      _fs.data[uri] = candidate;
      if (!await _crashesOnCompile(initialComponent)) {
        // Deleting 1 char didn't crash; don't try to delete anymore starting
        // here.
        offset++;
        continue;
      }

      // Find how long we can go.
      int crashingAt = 1;
      int? noLongerCrashingAt;
      while (true) {
        int deleteChars = 2 * crashingAt;
        if (offset + deleteChars > latestCrashData.length) {
          deleteChars = latestCrashData.length - offset;
        }
        builder = new BytesBuilder();
        builder.add(_sublist(latestCrashData, 0, offset));
        builder.add(_sublist(
            latestCrashData, offset + deleteChars, latestCrashData.length));
        candidate = builder.takeBytes();
        _fs.data[uri] = candidate;
        if (!await _crashesOnCompile(initialComponent)) {
          noLongerCrashingAt = deleteChars;
          break;
        }
        crashingAt = deleteChars;
        if (crashingAt + offset == latestCrashData.length) break;
      }

      if (noLongerCrashingAt == null) {
        // We can delete the rest.
        latestCrashData = candidate;
        continue;
      }

      // Binary search between [crashingAt] and [noLongerCrashingAt].
      while (crashingAt < noLongerCrashingAt!) {
        int mid = noLongerCrashingAt -
            ((noLongerCrashingAt - crashingAt) >>
                1); // Get middle, rounding up.
        builder = new BytesBuilder();
        builder.add(_sublist(latestCrashData, 0, offset));
        builder.add(
            _sublist(latestCrashData, offset + mid, latestCrashData.length));
        candidate = builder.takeBytes();
        _fs.data[uri] = candidate;
        if (await _crashesOnCompile(initialComponent)) {
          crashingAt = mid;
        } else {
          // [noLongerCrashingAt] might actually crash now.
          noLongerCrashingAt = mid - 1;
        }
      }

      // This is basically an assert.
      builder = new BytesBuilder();
      builder.add(_sublist(latestCrashData, 0, offset));
      builder.add(_sublist(
          latestCrashData, offset + crashingAt, latestCrashData.length));
      candidate = builder.takeBytes();
      _fs.data[uri] = candidate;
      if (!await _crashesOnCompile(initialComponent)) {
        throw "Error in binary search.";
      }
      latestCrashData = candidate;
    }

    _fs.data[uri] = latestCrashData;
  }

  Future<void> _tryToRemoveUnreferencedFileContent(Component initialComponent,
      {bool deleteFile = false}) async {
    // Check if there now are any unused files.
    if (_latestComponent == null) return;
    Set<Uri> neededUris = _latestComponent!.uriToSource.keys.toSet();
    Map<Uri?, Uint8List?> copy = new Map.of(_fs.data);
    bool removedSome = false;
    if (await _shouldQuit()) return;
    for (MapEntry<Uri?, Uint8List?> entry in _fs.data.entries) {
      if (entry.value == null) continue;
      if (!deleteFile && entry.value!.isEmpty) continue;
      if (!entry.key.toString().endsWith(".dart")) continue;
      if (!neededUris.contains(entry.key) &&
          (deleteFile || _fs.data[entry.key]!.length != 0)) {
        if (deleteFile) {
          _fs.data[entry.key] = null;
        } else {
          _fs.data[entry.key] = new Uint8List(0);
        }
        print(" => Can probably also delete ${entry.key}");
        removedSome = true;
      }
    }
    if (removedSome) {
      if (await _crashesOnCompile(initialComponent)) {
        print(" => Yes; Could remove those too!");
      } else {
        print(" => No; Couldn't remove those too!");
        _fs.data.clear();
        _fs.data.addAll(copy);
      }
    }
  }

  Future<void> _deleteContent(
      List<Uri> uris, int uriIndex, bool limitTo1, Component initialComponent,
      {bool deleteFile = false}) async {
    String extraMessageText = "all content of ";
    if (deleteFile) extraMessageText = "";

    if (!limitTo1) {
      if (await _shouldQuit()) return;
      Map<Uri?, Uint8List?> copy = new Map.of(_fs.data);
      // Try to remove content of i and the next 9 (10 files in total).
      for (int j = uriIndex; j < uriIndex + 10 && j < uris.length; j++) {
        Uri uri = uris[j];
        if (deleteFile) {
          _fs.data[uri] = null;
        } else {
          _fs.data[uri] = new Uint8List(0);
        }
      }
      if (!await _crashesOnCompile(initialComponent)) {
        // Couldn't delete all 10 files. Restore and try the single one.
        _fs.data.clear();
        _fs.data.addAll(copy);
      } else {
        for (int j = uriIndex; j < uriIndex + 10 && j < uris.length; j++) {
          Uri uri = uris[j];
          print("Can delete ${extraMessageText}file $uri");
        }
        await _tryToRemoveUnreferencedFileContent(initialComponent,
            deleteFile: deleteFile);
        return;
      }
    }

    if (await _shouldQuit()) return;
    Uri uri = uris[uriIndex];
    Uint8List? data = _fs.data[uri];
    if (deleteFile) {
      _fs.data[uri] = null;
    } else {
      _fs.data[uri] = new Uint8List(0);
    }
    if (!await _crashesOnCompile(initialComponent)) {
      print(
          "Can't delete ${extraMessageText}file $uri -- keeping it (for now)");
      _fs.data[uri] = data;

      // For dart files we can't truncate completely try to "outline" them
      // instead.
      if (uri.toString().endsWith(".dart")) {
        Version languageVersion = _getLanguageVersion(uri, crashOnFail: false);
        String? textualOutlined = textualOutline(
                data!, _getScannerConfiguration(languageVersion),
                enablePatterns:
                    languageVersion >= ExperimentalFlag.patterns.enabledVersion,
                enableEnhancedParts: languageVersion >=
                    ExperimentalFlag.enhancedParts.enabledVersion)
            ?.replaceAll(RegExp(r'\n+'), "\n");

        bool outlined = false;
        if (textualOutlined != null) {
          Uint8List candidate = utf8.encode(textualOutlined);
          // Because textual outline doesn't do the right thing for nnbd, only
          // replace if it's syntactically valid.
          if (candidate.length != _fs.data[uri]!.length &&
              _parsesWithoutError(candidate)) {
            if (await _shouldQuit()) return;
            _fs.data[uri] = candidate;
            if (!await _crashesOnCompile(initialComponent)) {
              print("Can't outline the file $uri -- keeping it (for now)");
              _fs.data[uri] = data;
            } else {
              outlined = true;
              print("Can outline the file $uri "
                  "(now ${_fs.data[uri]!.length} bytes)");
            }
          }
        }
        if (!outlined) {
          // We can probably at least remove all comments then...
          try {
            List<String> strings = utf8.decode(_fs.data[uri]!).split("\n");
            List<String> stringsLeft = [];
            for (String string in strings) {
              if (!string.trim().startsWith("//")) stringsLeft.add(string);
            }

            Uint8List candidate = utf8.encode(stringsLeft.join("\n"));
            if (candidate.length != _fs.data[uri]!.length) {
              if (await _shouldQuit()) return;
              _fs.data[uri] = candidate;
              if (!await _crashesOnCompile(initialComponent)) {
                print("Can't remove comments for file $uri -- "
                    "keeping it (for now)");
                _fs.data[uri] = data;
              } else {
                print("Removed comments for the file $uri");
              }
            }
          } catch (e) {
            // crash in scanner/parser --- keep original file. This crash might
            // be what we're looking for!
          }
        }
      }
    } else {
      print("Can delete ${extraMessageText}file $uri");
      await _tryToRemoveUnreferencedFileContent(initialComponent);
    }
  }

  Future<void> _deleteBlocksOld(Uri uri, Component initialComponent) async {
    if (uri.toString().endsWith(".json")) {
      // Try to find annoying
      //
      //    },
      //    {
      //    }
      //
      // part of json and remove it.
      Uint8List data = _fs.data[uri]!;
      String string = utf8.decode(data);
      List<String> lines = string.split("\n");
      for (int i = 0; i < lines.length - 2; i++) {
        if (lines[i].trim() == "}," &&
            lines[i + 1].trim() == "{" &&
            lines[i + 2].trim() == "}") {
          // This is the pattern we wanted to find. Remove it.
          lines.removeRange(i, i + 2);
          i--;
        }
      }
      string = lines.join("\n");
      _fs.data[uri] = utf8.encode(string);
      if (!await _crashesOnCompile(initialComponent)) {
        // For some reason that didn't work.
        _fs.data[uri] = data;
      }
    }
    if (!uri.toString().endsWith(".dart")) return;

    Uint8List data = _fs.data[uri]!;
    Uint8List latestCrashData = data;

    List<int> lineStarts = [];

    Token firstToken =
        parser_suite.scanRawBytes(data, _scannerConfiguration, lineStarts);

    int compileTry = 0;
    Token? token = firstToken;
    while (token is ErrorToken) {
      token = token.next;
    }
    List<_Replacement> replacements = [];
    while (token != null && !token.isEof) {
      bool tryCompile = false;
      Token skipToToken = token;
      // Skip very small blocks (e.g. "{}" or "{\n}");
      if (token.endGroup != null && token.offset + 3 < token.endGroup!.offset) {
        replacements
            .add(new _Replacement(token.offset, token.endGroup!.offset));
        tryCompile = true;
        skipToToken = token.endGroup!;
      } else if (token.lexeme == "@") {
        if (token.next!.next!.endGroup != null) {
          int end = token.next!.next!.endGroup!.offset;
          skipToToken = token.next!.next!.endGroup!;
          replacements.add(new _Replacement(token.offset - 1, end + 1));
          tryCompile = true;
        }
      } else if (token.lexeme == "assert") {
        if (token.next!.endGroup != null) {
          int end = token.next!.endGroup!.offset;
          skipToToken = token.next!.endGroup!;
          if (token.next!.endGroup!.next!.lexeme == ",") {
            end = token.next!.endGroup!.next!.offset;
            skipToToken = token.next!.endGroup!.next!;
          }
          // +/- 1 to not include the start and the end character.
          replacements.add(new _Replacement(token.offset - 1, end + 1));
          tryCompile = true;
        }
      } else if ((token.lexeme == "abstract" &&
              token.next!.lexeme == "class") ||
          token.lexeme == "class" ||
          token.lexeme == "enum" ||
          token.lexeme == "mixin" ||
          token.lexeme == "static" ||
          token.next!.lexeme == "get" ||
          token.next!.lexeme == "set" ||
          token.next!.next!.lexeme == "(" ||
          (token.next!.lexeme == "<" &&
              token.next!.endGroup != null &&
              token.next!.endGroup!.next!.next!.lexeme == "(")) {
        // Try to find and remove the entire class/enum/mixin/
        // static procedure/getter/setter/simple procedure.
        Token bracket = token;
        for (int i = 0; i < 20; i++) {
          // Find "{", but only go a maximum of 20 tokens to do that.
          bracket = bracket.next!;
          if (bracket.lexeme == "{" && bracket.endGroup != null) {
            break;
          } else if ((bracket.lexeme == "(" || bracket.lexeme == "<") &&
              bracket.endGroup != null) {
            bracket = bracket.endGroup!;
          }
        }
        if (bracket.lexeme == "{" && bracket.endGroup != null) {
          int end = bracket.endGroup!.offset;
          skipToToken = bracket.endGroup!;
          // +/- 1 to not include the start and the end character.
          replacements.add(new _Replacement(token.offset - 1, end + 1));
          tryCompile = true;
        }
      }

      if (tryCompile) {
        if (await _shouldQuit()) break;
        if (_skip) {
          _skip = false;
          break;
        }
        stdout.write(".");
        compileTry++;
        if (compileTry % 50 == 0) {
          stdout.write("(at $compileTry)\n");
        }
        Uint8List candidate = _replaceRange(replacements, data);
        _fs.data[uri] = candidate;
        if (await _crashesOnCompile(initialComponent)) {
          print("Found block from "
              "${replacements.last.from} to "
              "${replacements.last.to} "
              "that can be removed.");
          latestCrashData = candidate;
          token = skipToToken;
        } else {
          // Couldn't delete that.
          replacements.removeLast();
        }
      }
      token = token.next;
    }
    _fs.data[uri] = latestCrashData;
  }

  Future<void> _deleteBlocks(final Uri uri, Component initialComponent) async {
    if (uri.toString().endsWith(".json")) {
      // Try to find annoying
      //
      //    },
      //    {
      //    }
      //
      // part of json and remove it.
      Uint8List data = _fs.data[uri]!;
      String string = utf8.decode(data);
      List<String> lines = string.split("\n");
      for (int i = 0; i < lines.length - 2; i++) {
        if (lines[i].trim() == "}," &&
            lines[i + 1].trim() == "{" &&
            lines[i + 2].trim() == "}") {
          // This is the pattern we wanted to find. Remove it.
          lines.removeRange(i, i + 2);
          i--;
        }
      }
      string = lines.join("\n");
      Uint8List candidate = utf8.encode(string);
      if (candidate.length != data.length) {
        _fs.data[uri] = candidate;
        if (!await _crashesOnCompile(initialComponent)) {
          // For some reason that didn't work.
          _fs.data[uri] = data;
        }
      }

      // Try to load json and remove blocks.
      try {
        Map json = jsonDecode(utf8.decode(data));
        Map jsonModified = new Map.of(json);
        List packages = json["packages"];
        List packagesModified = new List.from(packages);
        jsonModified["packages"] = packagesModified;
        int i = 0;
        print("Note there's ${packagesModified.length} packages in .json");
        JsonEncoder jsonEncoder = new JsonEncoder.withIndent("  ");
        while (i < packagesModified.length) {
          var oldEntry = packagesModified.removeAt(i);
          String jsonString = jsonEncoder.convert(jsonModified);
          candidate = utf8.encode(jsonString);
          Uint8List? previous = _fs.data[uri];
          _fs.data[uri] = candidate;
          if (!await _crashesOnCompile(initialComponent)) {
            // Couldn't remove that part.
            _fs.data[uri] = previous;
            packagesModified.insert(i, oldEntry);
            i++;
          } else {
            print("Removed package from .json "
                "(${packagesModified.length} left).");
          }
        }
      } catch (e) {
        // Couldn't decode it, so don't try to do anything.
      }
      return;
    }
    if (!uri.toString().endsWith(".dart")) return;

    Uint8List data = _fs.data[uri]!;
    CompilationUnitEnd ast =
        getAST(data, includeBody: true, includeComments: false);

    _CompilationHelperClass helper = new _CompilationHelperClass(data);

    // Try to remove top level things one at a time.
    for (ParserAstNode child in ast.children!) {
      bool shouldCompile = false;
      String what = "";
      if (child.isClass()) {
        ClassDeclarationEnd cls = child.asClass();
        helper.replacements.add(new _Replacement(
            cls.beginToken.offset - 1, cls.endToken.offset + 1));
        shouldCompile = true;
        what = "class";
      } else if (child.isMixinDeclaration()) {
        MixinDeclarationEnd decl = child.asMixinDeclaration();
        helper.replacements.add(new _Replacement(
            decl.beginToken.offset - 1, decl.endToken.offset + 1));
        shouldCompile = true;
        what = "mixin";
      } else if (child.isNamedMixinDeclaration()) {
        NamedMixinApplicationEnd decl = child.asNamedMixinDeclaration();
        helper.replacements.add(
            new _Replacement(decl.begin.offset - 1, decl.endToken.offset + 1));
        shouldCompile = true;
        what = "named mixin";
      } else if (child.isExtension()) {
        ExtensionDeclarationEnd decl = child.asExtension();
        helper.replacements.add(new _Replacement(
            decl.extensionKeyword.offset - 1, decl.endToken.offset + 1));
        shouldCompile = true;
        what = "extension";
      } else if (child.isTopLevelFields()) {
        TopLevelFieldsEnd decl = child.asTopLevelFields();
        helper.replacements.add(new _Replacement(
            decl.beginToken.offset - 1, decl.endToken.offset + 1));
        shouldCompile = true;
        what = "toplevel fields";
      } else if (child.isTopLevelMethod()) {
        TopLevelMethodEnd decl = child.asTopLevelMethod();
        helper.replacements.add(new _Replacement(
            decl.beginToken.offset - 1, decl.endToken.offset + 1));
        shouldCompile = true;
        what = "toplevel method";
      } else if (child.isEnum()) {
        EnumEnd decl = child.asEnum();
        helper.replacements.add(new _Replacement(
            decl.enumKeyword.offset - 1, decl.leftBrace.endGroup!.offset + 1));
        shouldCompile = true;
        what = "enum";
      } else if (child.isTypedef()) {
        TypedefEnd decl = child.asTypedef();
        helper.replacements.add(new _Replacement(
            decl.typedefKeyword.offset - 1, decl.endToken.offset + 1));
        shouldCompile = true;
        what = "typedef";
      } else if (child.isMetadata()) {
        MetadataStarEnd decl = child.asMetadata();
        List<MetadataEnd> metadata = decl.getMetadataEntries();
        if (metadata.isNotEmpty) {
          helper.replacements.add(new _Replacement(
              metadata.first.beginToken.offset - 1,
              metadata.last.endToken.charEnd));
          shouldCompile = true;
        }
        what = "metadata";
      } else if (child.isImport()) {
        ImportEnd decl = child.asImport();
        helper.replacements.add(new _Replacement(
            decl.importKeyword.offset - 1, decl.semicolon!.offset + 1));
        shouldCompile = true;
        what = "import";
      } else if (child.isExport()) {
        ExportEnd decl = child.asExport();
        helper.replacements.add(new _Replacement(
            decl.exportKeyword.offset - 1, decl.semicolon.offset + 1));
        shouldCompile = true;
        what = "export";
      } else if (child.isLibraryName()) {
        LibraryNameEnd decl = child.asLibraryName();
        helper.replacements.add(new _Replacement(
            decl.libraryKeyword.offset - 1, decl.semicolon.offset + 1));
        shouldCompile = true;
        what = "library name";
      } else if (child.isPart()) {
        PartEnd decl = child.asPart();
        helper.replacements.add(new _Replacement(
            decl.partKeyword.offset - 1, decl.semicolon.offset + 1));
        shouldCompile = true;
        what = "part";
      } else if (child.isPartOf()) {
        PartOfEnd decl = child.asPartOf();
        helper.replacements.add(new _Replacement(
            decl.partKeyword.offset - 1, decl.semicolon.offset + 1));
        shouldCompile = true;
        what = "part of";
      } else if (child.isScript()) {
        ScriptHandle decl = child.asScript();
        helper.replacements.add(new _Replacement(
            decl.token.offset - 1, decl.token.offset + decl.token.length));
        shouldCompile = true;
        what = "script";
      } else if (child.isExtensionType()) {
        ExtensionTypeDeclarationEnd decl = child.asExtensionType();
        helper.replacements.add(new _Replacement(
            decl.extensionKeyword.offset - 1, decl.endToken.charEnd));
        shouldCompile = true;
        what = "extension type";
      }

      if (shouldCompile) {
        bool success =
            await _tryReplaceAndCompile(helper, uri, initialComponent, what);
        if (helper.shouldQuit) return;
        if (!success) {
          if (child.isClass()) {
            // Also try to remove all content of the class.
            ClassDeclarationEnd decl = child.asClass();
            ClassOrMixinOrExtensionBodyEnd body =
                decl.getClassOrMixinOrExtensionBody();
            if (body.beginToken.offset + 2 < body.endToken.offset) {
              helper.replacements.add(new _Replacement(
                  body.beginToken.offset, body.endToken.offset));
              what = "class body";
              success = await _tryReplaceAndCompile(
                  helper, uri, initialComponent, what);
              if (helper.shouldQuit) return;
            }

            if (!success) {
              // Also try to remove members one at a time.
              await _deleteBlocksHelper(body, helper, uri, initialComponent);
            }

            // Try to remove "extends", "implements" etc.
            // TODO(jensj): The below removes from the "extends" (etc) until
            // (but excluding) the "{". This should be improved so it can remove
            // _one_ part at a time. E:g. if it says "class A implements B, C {"
            // we could try to remove "B, " or ", C" etc.
            if (decl.getClassExtends().extendsKeyword != null) {
              helper.replacements.add(new _Replacement(
                  decl.getClassExtends().extendsKeyword!.offset - 1,
                  body.beginToken.offset));
              what = "class extends";
              success = await _tryReplaceAndCompile(
                  helper, uri, initialComponent, what);
              if (helper.shouldQuit) return;
            }
            if (decl.getClassImplements().implementsKeyword != null) {
              helper.replacements.add(new _Replacement(
                  decl.getClassImplements().implementsKeyword!.offset - 1,
                  body.beginToken.offset));
              what = "class implements";
              success = await _tryReplaceAndCompile(
                  helper, uri, initialComponent, what);
              if (helper.shouldQuit) return;
            }
            if (decl.getClassWithClause() != null) {
              helper.replacements.add(new _Replacement(
                  decl.getClassWithClause()!.withKeyword.offset - 1,
                  body.beginToken.offset));
              what = "class with clause";
              success = await _tryReplaceAndCompile(
                  helper, uri, initialComponent, what);
              if (helper.shouldQuit) return;
            }
          } else if (child.isMixinDeclaration()) {
            // Also try to remove all content of the mixin.
            MixinDeclarationEnd decl = child.asMixinDeclaration();
            ClassOrMixinOrExtensionBodyEnd body =
                decl.getClassOrMixinOrExtensionBody();
            if (body.beginToken.offset + 2 < body.endToken.offset) {
              helper.replacements.add(new _Replacement(
                  body.beginToken.offset, body.endToken.offset));
              what = "mixin body";
              success = await _tryReplaceAndCompile(
                  helper, uri, initialComponent, what);
              if (helper.shouldQuit) return;
            }

            if (!success) {
              await _deleteBlocksHelper(body, helper, uri, initialComponent);
            }
          } else if (child.isExtensionType()) {
            // Also try to remove all content of the extension type.
            ExtensionTypeDeclarationEnd decl = child.asExtensionType();
            ClassOrMixinOrExtensionBodyEnd body =
                decl.getClassOrMixinOrExtensionBody();
            if (body.beginToken.offset + 2 < body.endToken.offset) {
              helper.replacements.add(new _Replacement(
                  body.beginToken.offset, body.endToken.offset));
              what = "extension type body";
              success = await _tryReplaceAndCompile(
                  helper, uri, initialComponent, what);
              if (helper.shouldQuit) return;
            }

            if (!success) {
              await _deleteBlocksHelper(body, helper, uri, initialComponent);
            }
          } else if (child.isTopLevelMethod()) {
            // Try to remove parameters.
            TopLevelMethodEnd decl = child.asTopLevelMethod();
            FormalParametersEnd? formal =
                decl.children?.whereType<FormalParametersEnd>().firstOrNull;
            if (formal != null) {
              if (formal.beginToken.offset + 2 < formal.endToken.offset) {
                helper.replacements.add(new _Replacement(
                    formal.beginToken.offset, formal.endToken.offset));
                what = "top level formals";
                success = await _tryReplaceAndCompile(
                    helper, uri, initialComponent, what);
                if (helper.shouldQuit) return;
              }
            }
          }
        }
      }
    }
  }

  Future<void> _deleteBlocksHelper(
      ClassOrMixinOrExtensionBodyEnd body,
      _CompilationHelperClass helper,
      final Uri uri,
      Component initialComponent) async {
    for (ParserAstNode child in body.children!) {
      bool shouldCompile = false;
      String what = "";
      if (child is MemberEnd) {
        if (child.isClassConstructor()) {
          ClassConstructorEnd memberDecl = child.getClassConstructor();
          helper.replacements.add(new _Replacement(
              memberDecl.beginToken.offset - 1,
              memberDecl.endToken.offset + 1));
          what = "class constructor";
          shouldCompile = true;
        } else if (child.isClassFields()) {
          ClassFieldsEnd memberDecl = child.getClassFields();
          helper.replacements.add(new _Replacement(
              memberDecl.beginToken.offset - 1,
              memberDecl.endToken.offset + 1));
          what = "class fields";
          shouldCompile = true;
        } else if (child.isClassMethod()) {
          ClassMethodEnd memberDecl = child.getClassMethod();
          helper.replacements.add(new _Replacement(
              memberDecl.beginToken.offset - 1,
              memberDecl.endToken.offset + 1));
          what = "class method";
          shouldCompile = true;
        } else if (child.isClassFactoryMethod()) {
          ClassFactoryMethodEnd memberDecl = child.getClassFactoryMethod();
          helper.replacements.add(new _Replacement(
              memberDecl.beginToken.offset - 1,
              memberDecl.endToken.offset + 1));
          what = "class factory method";
          shouldCompile = true;
        } else if (child.isMixinConstructor()) {
          MixinConstructorEnd memberDecl = child.getMixinConstructor();
          helper.replacements.add(new _Replacement(
              memberDecl.beginToken.offset - 1,
              memberDecl.endToken.offset + 1));
          what = "mixin constructor";
          shouldCompile = true;
        } else if (child.isMixinFields()) {
          MixinFieldsEnd memberDecl = child.getMixinFields();
          helper.replacements.add(new _Replacement(
              memberDecl.beginToken.offset - 1,
              memberDecl.endToken.offset + 1));
          what = "mixin fields";
          shouldCompile = true;
        } else if (child.isMixinMethod()) {
          MixinMethodEnd memberDecl = child.getMixinMethod();
          helper.replacements.add(new _Replacement(
              memberDecl.beginToken.offset - 1,
              memberDecl.endToken.offset + 1));
          what = "mixin method";
          shouldCompile = true;
        } else if (child.isMixinFactoryMethod()) {
          MixinFactoryMethodEnd memberDecl = child.getMixinFactoryMethod();
          helper.replacements.add(new _Replacement(
              memberDecl.beginToken.offset - 1,
              memberDecl.endToken.offset + 1));
          what = "mixin factory method";
          shouldCompile = true;
        } else if (child.isExtensionTypeConstructor()) {
          var memberDecl = child.getExtensionTypeConstructor();
          helper.replacements.add(new _Replacement(
              memberDecl.beginToken.offset - 1,
              memberDecl.endToken.offset + 1));
          what = "extension type constructor";
          shouldCompile = true;
        } else if (child.isExtensionTypeFields()) {
          ExtensionTypeFieldsEnd memberDecl = child.getExtensionTypeFields();
          helper.replacements.add(new _Replacement(
              memberDecl.beginToken.offset - 1,
              memberDecl.endToken.offset + 1));
          what = "extension type fields";
          shouldCompile = true;
        } else if (child.isExtensionTypeMethod()) {
          ExtensionTypeMethodEnd memberDecl = child.getExtensionTypeMethod();
          helper.replacements.add(new _Replacement(
              memberDecl.beginToken.offset - 1,
              memberDecl.endToken.offset + 1));
          what = "extension type method";
          shouldCompile = true;
        } else if (child.isExtensionTypeFactoryMethod()) {
          ExtensionTypeFactoryMethodEnd memberDecl =
              child.getExtensionTypeFactoryMethod();
          helper.replacements.add(new _Replacement(
              memberDecl.beginToken.offset - 1,
              memberDecl.endToken.offset + 1));
          what = "extension type factory method";
          shouldCompile = true;
        } else if (child.isExtensionConstructor()) {
          var memberDecl = child.getExtensionConstructor();
          helper.replacements.add(new _Replacement(
              memberDecl.beginToken.offset - 1,
              memberDecl.endToken.offset + 1));
          what = "extension constructor";
          shouldCompile = true;
        } else if (child.isExtensionFields()) {
          ExtensionFieldsEnd memberDecl = child.getExtensionFields();
          helper.replacements.add(new _Replacement(
              memberDecl.beginToken.offset - 1,
              memberDecl.endToken.offset + 1));
          what = "extension fields";
          shouldCompile = true;
        } else if (child.isExtensionMethod()) {
          ExtensionMethodEnd memberDecl = child.getExtensionMethod();
          helper.replacements.add(new _Replacement(
              memberDecl.beginToken.offset - 1,
              memberDecl.endToken.offset + 1));
          what = "extension method";
          shouldCompile = true;
        } else if (child.isExtensionFactoryMethod()) {
          ExtensionFactoryMethodEnd memberDecl =
              child.getExtensionFactoryMethod();
          helper.replacements.add(new _Replacement(
              memberDecl.beginToken.offset - 1,
              memberDecl.endToken.offset + 1));
          what = "extension factory method";
          shouldCompile = true;
        } else {
          // throw "$child --- ${child.children}";
          continue;
        }
      } else if (child.isMetadata()) {
        MetadataStarEnd decl = child.asMetadata();
        List<MetadataEnd> metadata = decl.getMetadataEntries();
        if (metadata.isNotEmpty) {
          helper.replacements.add(new _Replacement(
              metadata.first.beginToken.offset - 1,
              metadata.last.endToken.charEnd));
          shouldCompile = true;
        }
        what = "metadata";
      }
      if (shouldCompile) {
        bool success =
            await _tryReplaceAndCompile(helper, uri, initialComponent, what);
        if (helper.shouldQuit) return;
        if (!success) {
          BlockFunctionBodyEnd? decl;
          if (child is MemberEnd) {
            if (child.isClassMethod()) {
              decl = child.getClassMethod().getBlockFunctionBody();
            } else if (child.isClassConstructor()) {
              decl = child.getClassConstructor().getBlockFunctionBody();
            }
            // TODO(jensj): The other ones too maybe?
          }
          if (decl != null &&
              decl.beginToken.offset + 2 < decl.endToken.offset) {
            helper.replacements.add(
                new _Replacement(decl.beginToken.offset, decl.endToken.offset));
            what = "class member content";
            await _tryReplaceAndCompile(helper, uri, initialComponent, what);
            if (helper.shouldQuit) return;
          }
        }
      }
    }
  }

  Future<bool> _tryReplaceAndCompile(_CompilationHelperClass data, Uri uri,
      Component initialComponent, String what) async {
    if (await _shouldQuit()) {
      data.shouldQuit = true;
      return false;
    }
    stdout.write(".");
    data.compileTry++;
    if (data.compileTry % 50 == 0) {
      stdout.write("(at ${data.compileTry})\n");
    }
    Uint8List candidate = _replaceRange(data.replacements, data.originalData);

    if (!_parsesWithoutError(candidate) &&
        _parsesWithoutError(data.originalData)) {
      print("WARNING: Parser error after stuff at ${StackTrace.current}");
      _parsesWithoutError(candidate);
      _parsesWithoutError(data.originalData);
    }

    _fs.data[uri] = candidate;
    if (await _crashesOnCompile(initialComponent)) {
      print("Found $what from "
          "${data.replacements.last.from} to "
          "${data.replacements.last.to} "
          "that can be removed.");
      data.latestCrashData = candidate;
      return true;
    } else {
      // Couldn't delete that.
      data.replacements.removeLast();
      _fs.data[uri] = data.latestCrashData;
      return false;
    }
  }

  Future<void> _deleteEmptyLines(Uri uri, Component initialComponent) async {
    Uint8List data = _fs.data[uri]!;
    List<Uint8List> lines = [];
    int start = 0;
    for (int i = 0; i < data.length; i++) {
      if (data[i] == _$LF) {
        if (i - start > 0) {
          lines.add(_sublist(data, start, i));
        }
        start = i + 1;
      }
    }
    if (data.length - start > 0) {
      lines.add(_sublist(data, start, data.length));
    }

    final BytesBuilder builder = new BytesBuilder();
    for (int j = 0; j < lines.length; j++) {
      if (builder.isNotEmpty) {
        builder.addByte(_$LF);
      }
      builder.add(lines[j]);
    }
    Uint8List candidate = builder.takeBytes();
    if (candidate.length == data.length) return;

    if (uri.path.endsWith(".dart") && !_parsesWithoutError(candidate)) {
      print("WARNING: Parser error after stuff at ${StackTrace.current}");
    }

    if (await _shouldQuit()) return;
    _fs.data[uri] = candidate;
    if (!await _crashesOnCompile(initialComponent)) {
      // For some reason the empty lines are important.
      _fs.data[uri] = data;
    } else {
      print("\nDeleted empty lines.");
    }
  }

  Future<void> _deleteLines(Uri uri, Component initialComponent) async {
    // Try to delete "lines".
    Uint8List data = _fs.data[uri]!;
    List<Uint8List> lines = [];
    int start = 0;
    for (int i = 0; i < data.length; i++) {
      if (data[i] == _$LF) {
        lines.add(_sublist(data, start, i));
        start = i + 1;
      }
    }
    lines.add(_sublist(data, start, data.length));
    List<bool> include = new List.filled(lines.length, true);
    Uint8List latestCrashData = data;
    int length = 1;
    int i = 0;
    while (i < lines.length) {
      if (await _shouldQuit()) break;
      if (_skip) {
        _skip = false;
        break;
      }
      stdout.write(".");
      if (i % 50 == 0) {
        stdout.write("(at $i of ${lines.length})\n");
      }
      if (i + length > lines.length) {
        length = lines.length - i;
      }
      for (int j = i; j < i + length; j++) {
        include[j] = false;
      }
      final BytesBuilder builder = new BytesBuilder();
      for (int j = 0; j < lines.length; j++) {
        if (include[j]) {
          if (builder.isNotEmpty) {
            builder.addByte(_$LF);
          }
          builder.add(lines[j]);
        }
      }
      Uint8List candidate = builder.takeBytes();
      _fs.data[uri] = candidate;
      if (!await _crashesOnCompile(initialComponent)) {
        // Didn't crash => Can't remove line i-j.
        for (int j = i; j < i + length; j++) {
          include[j] = true;
        }
        if (length > 2) {
          // Retry with length 2 at same i.
          // The idea here is that for instance formatted json might have lines
          // looking like
          // {
          // }
          // where deleting just one line makes it invalid.
          length = 2;
        } else if (length > 1) {
          // Retry with length 1 at same i.
          length = 1;
        } else {
          // Couldn't with length 1 either.
          i++;
        }
      } else {
        print("\nCan delete line $i (inclusive) - ${i + length} (exclusive) "
            "(of ${lines.length})");
        latestCrashData = candidate;
        i += length;
        length *= 2;
      }
    }
    _fs.data[uri] = latestCrashData;
  }

  Future<bool> _tryRemoveIfNotKnownByCompiler(
      Uri? uri, initialComponent) async {
    if (_fs.data[uri] == null || _fs.data[uri]!.isEmpty) return false;
    if (!uri.toString().endsWith(".dart")) return false;

    if (_knownByCompiler(uri!)) return false;

    // Compiler might not know this. Can we delete it?
    await _deleteContent([uri], 0, true, initialComponent);
    if (_fs.data[uri] == null || _fs.data[uri]!.isEmpty) {
      await _deleteContent([uri], 0, true, initialComponent, deleteFile: true);
      return true;
    }

    return false;
  }

  bool _knownByCompiler(Uri uri) {
    LibraryBuilder? libraryBuilder = _latestKernelTarget!.loader
        .lookupLoadedLibraryBuilder(_getImportUri(uri));
    if (libraryBuilder != null) {
      return true;
    }
    // TODO(jensj): Parts.
    return false;
  }

  ScannerConfiguration _getScannerConfiguration(Version languageVersion) {
    return new ScannerConfiguration(
        enableTripleShift:
            languageVersion >= ExperimentalFlag.tripleShift.enabledVersion);
  }

  Version _getLanguageVersion(Uri uri, {bool crashOnFail = true}) {
    if (_latestCrashingKnownInitialBuilders == null) {
      // It crashed on the first compile so we have no builders.
      // We'll just return something.
      return ExperimentalFlag.nonNullable.enabledVersion;
    }
    Uri asImportUri = _getImportUri(uri);
    LibraryBuilder? libraryBuilder =
        _latestCrashingKnownInitialBuilders![asImportUri];
    if (libraryBuilder != null) {
      return libraryBuilder.languageVersion;
    }
    print("Couldn't lookup $uri ($asImportUri)");
    for (LibraryBuilder libraryBuilder
        in _latestCrashingKnownInitialBuilders!.values) {
      if (libraryBuilder.importUri == uri) {
        print("Found $uri as ${libraryBuilder.importUri} (!= ${asImportUri})");
        return libraryBuilder.languageVersion;
      }
      if (libraryBuilder.fileUri == uri) {
        print("Found $uri as file uri ${libraryBuilder.fileUri}");
        return libraryBuilder.languageVersion;
      }
      // Check parts too.
      for (LibraryPart part in libraryBuilder.library.parts) {
        Uri thisPartUri = libraryBuilder.importUri.resolve(part.partUri);
        if (thisPartUri == uri || thisPartUri == asImportUri) {
          print("Found $uri as part of ${libraryBuilder.importUri}");
          return libraryBuilder.languageVersion;
        }
        thisPartUri = libraryBuilder.fileUri.resolve(part.partUri);
        if (thisPartUri == uri || thisPartUri == asImportUri) {
          print("Found $uri as part of ${libraryBuilder.importUri}");
          return libraryBuilder.languageVersion;
        }
      }
    }
    if (crashOnFail) {
      throw "Couldn't lookup $uri ($asImportUri) at all!"
          "\n\n"
          "$_latestCrashingKnownInitialBuilders"
          "\n\n"
          "";
    } else {
      return defaultLanguageVersion;
    }
  }

  Future<bool> _crashesOnCompile(Component initialComponent) async {
    IncrementalCompiler incrementalCompiler;
    _gotWantedError = false;
    bool didNotGetWantedErrorAfterFirstCompile = true;
    CompilerContext context = _setupCompilerContext();
    if (_settings.noPlatform) {
      incrementalCompiler = new IncrementalCompiler(context);
    } else if (_settings.initialOnlyOutline) {
      incrementalCompiler = new IncrementalCompiler(context, null, true);
    } else {
      incrementalCompiler = new IncrementalCompiler.fromComponent(
          context, initialComponent, true);
    }
    for (Uri entry in _entryUris) {
      incrementalCompiler.invalidate(entry);
    }
    Map<Uri, LibraryBuilder>? knownInitialBuilders;
    try {
      IncrementalCompilerResult incrementalCompilerResult =
          await incrementalCompiler.computeDelta();
      _latestKernelTarget = incrementalCompiler.kernelTargetForTesting!;
      _latestComponent = incrementalCompilerResult.component;
      if (_settings.serialize) {
        // We're asked to serialize, probably because it crashes in
        // serialization.
        ByteSink sink = new ByteSink();
        BinaryPrinter printer = new BinaryPrinter(sink);
        printer.writeComponentFile(_latestComponent!);
      }

      knownInitialBuilders = <Uri, LibraryBuilder>{
        for (LibraryBuilder v
            in _latestKernelTarget!.loader.loadedLibraryBuilders)
          v.importUri: v
      };

      if (_gotWantedError) didNotGetWantedErrorAfterFirstCompile = false;

      if (_settings.loadFromComponentBeforeInvalidate) {
        incrementalCompiler =
            new IncrementalCompiler.fromComponent(context, _latestComponent!);
      }

      if (_settings.invalidateAllAtOnce && _settings.invalidate.isNotEmpty) {
        for (Uri uri in _settings.invalidate) {
          incrementalCompiler.invalidate(uri);
        }

        IncrementalCompilerResult deltaResult =
            await incrementalCompiler.computeDelta();
        _latestKernelTarget = incrementalCompiler.kernelTargetForTesting!;
        Component delta = deltaResult.component;
        if (_settings.serialize) {
          // We're asked to serialize, probably because it crashes in
          // serialization.
          ByteSink sink = new ByteSink();
          BinaryPrinter printer = new BinaryPrinter(sink);
          printer.writeComponentFile(delta);
          sink.builder.takeBytes();
        }
      } else {
        for (Uri uri in _settings.invalidate) {
          incrementalCompiler.invalidate(uri);
          IncrementalCompilerResult deltaResult =
              await incrementalCompiler.computeDelta();
          _latestKernelTarget = incrementalCompiler.kernelTargetForTesting!;
          Component delta = deltaResult.component;
          if (_settings.serialize) {
            // We're asked to serialize, probably because it crashes in
            // serialization.
            ByteSink sink = new ByteSink();
            BinaryPrinter printer = new BinaryPrinter(sink);
            printer.writeComponentFile(delta);
            sink.builder.takeBytes();
          }
        }
      }
      if (_settings.lookForErrorErrorOnReload != null &&
          _gotWantedError &&
          didNotGetWantedErrorAfterFirstCompile) {
        // We throw here so the "compile crashes"... This is looking for
        // crashes after-all :)
        throw "Got the wanted error!";
      }
      _latestComponent = null; // if it didn't crash this isn't relevant.
      return false;
    } catch (e, st) {
      // Find line with #0 in it.
      String eWithSt = "$e\n\n$st";
      List<String> lines = eWithSt.split("\n");
      String foundLine = "";
      int lookFor = 0;
      for (String line in lines) {
        if (line.startsWith("#$lookFor")) {
          foundLine += line;
          lookFor++;
          if (lookFor >= _settings.stackTraceMatches) {
            break;
          } else {
            foundLine += "\n";
          }
        }
      }

      if (_expectedCrashLine == null) {
        print("Got '$foundLine'");
        _expectedCrashLine = foundLine;
        _latestCrashingIncrementalCompiler = incrementalCompiler;
        _latestCrashingKnownInitialBuilders = knownInitialBuilders;
        return true;
      } else if (foundLine == _expectedCrashLine) {
        _latestCrashingIncrementalCompiler = incrementalCompiler;
        _latestCrashingKnownInitialBuilders = knownInitialBuilders;
        return true;
      } else {
        if (_settings.autoUncoverAllCrashes &&
            !_settings.allAutoRedirects.contains(foundLine)) {
          print("Crashed, but another place: $foundLine");
          print(" ==> Adding to auto redirects!");
          // Add the current one too, so we don't rediscover that one once we
          // try minimizing the new ones.
          _settings.allAutoRedirects.add(_expectedCrashLine!);
          _settings.allAutoRedirects.add(foundLine);
          _settings.fileSystems.add(_fs.toJson());
        } else if (_settings.askAboutRedirectCrashTarget &&
            !_settings.askedAboutRedirect.contains(foundLine)) {
          print("Crashed, but another place: $foundLine");
          while (true) {
            // Add the current one too, so we don't rediscover that again
            // and asks about going back to it.
            _settings.askedAboutRedirect.add(_expectedCrashLine!);
            _settings.askedAboutRedirect.add(foundLine);
            print(eWithSt);
            print("Should we redirect to searching for that? (y/n)");
            String answer = stdin.readLineSync()!;
            if (answer == "yes" || answer == "y") {
              _expectedCrashLine = foundLine;
              _latestCrashingIncrementalCompiler = incrementalCompiler;
              _latestCrashingKnownInitialBuilders = knownInitialBuilders;
              return true;
            } else if (answer == "no" || answer == "n") {
              break;
            } else {
              print("Didn't get that answer. "
                  "Please answer 'yes, 'y', 'no' or 'n'");
            }
          }
        }
        return false;
      }
    }
  }

  Future<Component> _getInitialComponent() async {
    IncrementalCompiler incrementalCompiler =
        new IncrementalCompiler(_setupCompilerContext());
    IncrementalCompilerResult incrementalCompilerResult =
        await incrementalCompiler.computeDelta();
    Component originalComponent = incrementalCompilerResult.component;
    return originalComponent;
  }

  CompilerContext _setupCompilerContext() {
    CompilerOptions options = getOptions();

    if (_settings.experimentalInvalidation) {
      options.explicitExperimentalFlags[
          ExperimentalFlag.alternativeInvalidationStrategy] = true;
    }

    TargetFlags targetFlags = new TargetFlags(
        trackWidgetCreation: _settings.widgetTransformation);
    Target target;
    switch (_settings.targetString) {
      case "vm":
        target = new VmTarget(targetFlags);
        break;
      case "flutter":
        target = new FlutterTarget(targetFlags);
        break;
      case "dartdevc":
        target = new DevCompilerTarget(targetFlags);
        break;
      case "dart2js":
        target = new Dart2jsTarget("dart2js", targetFlags);
        break;
      default:
        throw "Unknown target '${_settings.targetString}'";
    }
    options.target = target;
    options.fileSystem = _fs;
    options.sdkRoot = null;
    options.sdkSummary = _settings.platformUri;
    options.packagesFileUri = _settings.packagesFileUri;
    options.omitPlatform = false;
    options.onDiagnostic = (DiagnosticMessage message) {
      // don't care.
      // Except if we're looking to trigger a specific error on reload.
      if (_settings.lookForErrorErrorOnReload != null &&
          message.ansiFormatted.first
              .contains(_settings.lookForErrorErrorOnReload!)) {
        _gotWantedError = true;
      }
    };
    if (_settings.noPlatform) {
      options.librariesSpecificationUri = null;
    }

    CompilerContext compilerContext = new CompilerContext(
        new ProcessedOptions(options: options, inputs: _entryUris));
    return compilerContext;
  }

  String _getFileAsStringContent(Uint8List rawBytes) {
    List<int> lineStarts = [];

    Token firstToken =
        parser_suite.scanRawBytes(rawBytes, _scannerConfiguration, lineStarts);

    ParserTestListener parserTestListener = new ParserTestListener(false);
    Parser parser = new Parser(parserTestListener,
        useImplicitCreationExpression: useImplicitCreationExpressionInCfe);
    parser.parseUnit(firstToken);
    String parsedString =
        parser_suite.tokenStreamToString(firstToken, lineStarts).toString();
    return parsedString;
  }

  bool _parsesWithoutError(Uint8List rawBytes) {
    Token firstToken =
        parser_suite.scanRawBytes(rawBytes, _scannerConfiguration, null);

    ParserErrorListener parserErrorListener = new ParserErrorListener();
    Parser parser = new Parser(parserErrorListener,
        useImplicitCreationExpression: useImplicitCreationExpressionInCfe);
    parser.parseUnit(firstToken);
    return !parserErrorListener.gotError;
  }

  ScannerConfiguration _scannerConfiguration =
      new ScannerConfiguration(enableTripleShift: true);

  List<int>? _dataCache;
  String? _dataCacheString;

  Uint8List _replaceRange(
      List<_Replacement> unsortedReplacements, Uint8List rawData) {
    // The offsets are character offsets, not byte offsets, so for non-ascii
    // they are not the same so we need to work on the string, not the bytes.
    if (identical(rawData, _dataCache)) {
      // cache up to date.
    } else {
      _dataCache = rawData;
      _dataCacheString = utf8.decode(rawData);
    }

    // The below assumes these are sorted.
    List<_Replacement> sortedReplacements =
        new List<_Replacement>.from(unsortedReplacements)..sort();
    final StringBuffer builder = new StringBuffer();
    int prev = 0;
    for (int i = 0; i < sortedReplacements.length; i++) {
      _Replacement replacement = sortedReplacements[i];
      for (int j = prev; j <= replacement.from; j++) {
        builder.writeCharCode(_dataCacheString!.codeUnitAt(j));
      }
      if (replacement.nullOrReplacement != null) {
        builder.write(replacement.nullOrReplacement);
      }
      prev = replacement.to;
    }
    for (int j = prev; j < _dataCacheString!.length; j++) {
      builder.writeCharCode(_dataCacheString!.codeUnitAt(j));
    }

    Uint8List candidate = utf8.encode(builder.toString());
    return candidate;
  }
}

class ParserErrorListener extends Listener {
  bool gotError = false;
  List<Message> messages = [];
  @override
  void handleRecoverableError(
      Message message, Token startToken, Token endToken) {
    gotError = true;
    messages.add(message);
  }
}

class _CompilationHelperClass {
  int compileTry = 0;
  bool shouldQuit = false;
  List<_Replacement> replacements = [];
  Uint8List latestCrashData;
  final Uint8List originalData;

  _CompilationHelperClass(this.originalData) : latestCrashData = originalData;
}

class _Replacement implements Comparable<_Replacement> {
  final int from;
  final int to;
  final String? nullOrReplacement;

  _Replacement(this.from, this.to, {this.nullOrReplacement});

  @override
  int compareTo(_Replacement other) {
    return from - other.from;
  }
}

class _FakeFileSystem extends FileSystem {
  bool _redirectAndRecord = true;
  bool _initialized = false;
  final Map<Uri?, Uint8List?> data = {};

  @override
  FileSystemEntity entityForUri(Uri uri) {
    return new _FakeFileSystemEntity(this, uri);
  }

  void initializeFromJson(Map<String, dynamic> json) {
    _initialized = true;
    _redirectAndRecord = json['_redirectAndRecord'];
    data.clear();
    List tmp = json['data'];
    for (int i = 0; i < tmp.length; i += 2) {
      Uri? key = tmp[i] == null ? null : Uri.parse(tmp[i]);
      if (tmp[i + 1] == null) {
        data[key] = null;
      } else if (tmp[i + 1] is String) {
        data[key] = utf8.encode(tmp[i + 1]);
      } else {
        data[key] = Uint8List.fromList(new List<int>.from(tmp[i + 1]));
      }
    }
  }

  Map<String, dynamic> toJson() {
    List tmp = [];
    for (MapEntry<Uri?, Uint8List?> entry in data.entries) {
      if (entry.value == null) continue;
      tmp.add(entry.key == null ? null : entry.key.toString());
      dynamic out = entry.value;
      if (entry.value != null && entry.value!.isNotEmpty) {
        try {
          String string = utf8.decode(entry.value!);
          out = string;
        } catch (e) {
          // not a string...
        }
      }
      tmp.add(out);
    }
    return {
      '_redirectAndRecord': _redirectAndRecord,
      'data': tmp,
    };
  }
}

class _FakeFileSystemEntity extends FileSystemEntity {
  final _FakeFileSystem fs;
  @override
  final Uri uri;
  _FakeFileSystemEntity(this.fs, this.uri);

  void _ensureCachedIfOk() {
    if (fs.data.containsKey(uri)) return;
    if (fs._initialized) return;
    if (!fs._redirectAndRecord) {
      throw "Asked for file in non-recording mode that wasn't known";
    }
    File f = new File.fromUri(uri);
    if (!f.existsSync()) {
      fs.data[uri] = null;
      return;
    }
    fs.data[uri] = f.readAsBytesSync();
  }

  @override
  Future<bool> exists() {
    _ensureCachedIfOk();
    Uint8List? data = fs.data[uri];
    if (data == null) return Future.value(false);
    return Future.value(true);
  }

  @override
  Future<bool> existsAsyncIfPossible() => exists();

  @override
  Future<Uint8List> readAsBytes() {
    _ensureCachedIfOk();
    Uint8List? data = fs.data[uri];
    if (data == null) throw new FileSystemException(uri, "File doesn't exist.");
    return Future.value(data);
  }

  @override
  Future<Uint8List> readAsBytesAsyncIfPossible() => readAsBytes();

  @override
  Future<String> readAsString() {
    _ensureCachedIfOk();
    Uint8List? data = fs.data[uri];
    if (data == null) throw new FileSystemException(uri, "File doesn't exist.");
    return Future.value(utf8.decode(data));
  }
}

class _DoesntCrashOnInput {
  _DoesntCrashOnInput();
}
