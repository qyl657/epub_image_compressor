import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:epub_image_compressor/service/epub_reference_rewriter.dart';
import 'package:epub_image_compressor/utils/app_util.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

String _zipExt(String path) {
  final dot = path.lastIndexOf('.');
  final slash = path.lastIndexOf('/');
  return (dot >= 0 && dot > slash) ? path.substring(dot).toLowerCase() : '';
}

String _zipBasename(String path) => path.substring(path.lastIndexOf('/') + 1);

String _toJpgPath(String path) {
  final dot = path.lastIndexOf('.');
  final slash = path.lastIndexOf('/');
  return (dot >= 0 && dot > slash)
      ? '${path.substring(0, dot)}.jpg'
      : '$path.jpg';
}

/// True when the PNG actually carries transparency (an alpha channel with at
/// least one pixel that is not fully opaque). Fully-opaque PNGs that merely
/// have an alpha channel return false and are safe to convert to JPEG.
bool _hasTransparency(img.Image image) {
  if (!image.hasAlpha) return false;
  final maxAlpha = image.maxChannelValue;
  return image.any((px) => px.a < maxAlpha);
}

/// Composite [image] onto a white background and return an RGB (no alpha)
/// image, so it can be encoded as JPEG without turning transparent areas black.
img.Image _flattenToWhite(img.Image image) {
  final maxChannel = image.maxChannelValue.toDouble();
  final out = img.Image(
    width: image.width,
    height: image.height,
    numChannels: 3,
  );
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final px = image.getPixel(x, y);
      final a = (px.a / maxChannel).clamp(0.0, 1.0);
      final inv = 1.0 - a;
      final r = (((px.r / maxChannel) * a + inv) * 255).round().clamp(0, 255);
      final g = (((px.g / maxChannel) * a + inv) * 255).round().clamp(0, 255);
      final b = (((px.b / maxChannel) * a + inv) * 255).round().clamp(0, 255);
      out.setPixelRgb(x, y, r, g, b);
    }
  }
  return out;
}

class CompressionOptions {
  const CompressionOptions({
    this.quality = 85,
    this.skipSmallImages = true,
    this.minImageBytes = 10 * 1024,
    this.pngLevel = 6,
    this.convertPngToJpg = true,
    this.convertTransparentPng = false,
    this.fullChroma = false,
  });

  final int quality;
  final bool skipSmallImages;
  final int minImageBytes;
  final int pngLevel;

  /// When true, opaque PNG images are re-encoded as JPEG (and the file is
  /// renamed .png -> .jpg with all EPUB references updated) to save space.
  final bool convertPngToJpg;

  /// When [convertPngToJpg] is true, also convert PNGs that carry real
  /// transparency by flattening them onto a white background first. Off by
  /// default because JPEG has no alpha and this is a lossy visual change.
  final bool convertTransparentPng;

  /// JPEG chroma sampling. `img.encodeJpg` defaults to 4:4:4, which costs
  /// 12-18% more bytes than the 4:2:0 that virtually every source JPEG uses;
  /// leaving it false also eats the whole shrink margin on already-compressed
  /// scans and makes them fall back to "keep original".
  final bool fullChroma;

  img.JpegChroma get jpegChroma =>
      fullChroma ? img.JpegChroma.yuv444 : img.JpegChroma.yuv420;

  Map<String, dynamic> toMap() {
    return {
      'quality': quality,
      'skipSmallImages': skipSmallImages,
      'minImageBytes': minImageBytes,
      'pngLevel': pngLevel,
      'convertPngToJpg': convertPngToJpg,
      'convertTransparentPng': convertTransparentPng,
      'fullChroma': fullChroma,
    };
  }

  factory CompressionOptions.fromMap(Map<String, dynamic> map) {
    return CompressionOptions(
      quality: map['quality'] as int? ?? 85,
      skipSmallImages: map['skipSmallImages'] as bool? ?? true,
      minImageBytes: map['minImageBytes'] as int? ?? 10 * 1024,
      pngLevel: map['pngLevel'] as int? ?? 6,
      convertPngToJpg: map['convertPngToJpg'] as bool? ?? true,
      convertTransparentPng: map['convertTransparentPng'] as bool? ?? false,
      fullChroma: map['fullChroma'] as bool? ?? false,
    );
  }

  CompressionOptions copyWith({
    int? quality,
    bool? skipSmallImages,
    int? minImageBytes,
    int? pngLevel,
    bool? convertPngToJpg,
    bool? convertTransparentPng,
    bool? fullChroma,
  }) {
    return CompressionOptions(
      quality: quality ?? this.quality,
      skipSmallImages: skipSmallImages ?? this.skipSmallImages,
      minImageBytes: minImageBytes ?? this.minImageBytes,
      pngLevel: pngLevel ?? this.pngLevel,
      convertPngToJpg: convertPngToJpg ?? this.convertPngToJpg,
      convertTransparentPng:
          convertTransparentPng ?? this.convertTransparentPng,
      fullChroma: fullChroma ?? this.fullChroma,
    );
  }
}

class CancellationToken {
  bool _isCancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _isCancelled;

  void cancel() {
    _isCancelled = true;
    for (final listener in List<void Function()>.from(_listeners)) {
      listener();
    }
  }

  void throwIfCancelled() {
    if (_isCancelled) {
      throw CompressionCancelled();
    }
  }

  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }
}

class CompressionProgress {
  CompressionProgress({
    required this.totalImages,
    required this.processedImages,
    required this.currentEntry,
  });

  final int totalImages;
  final int processedImages;
  final String currentEntry;

  double get percent => totalImages == 0 ? 1.0 : processedImages / totalImages;
}

class CompressionSummary {
  CompressionSummary({
    required this.outputPath,
    required this.totalImages,
    required this.processedImages,
    required this.savedBytes,
    required this.elapsed,
    required this.cancelled,
  });

  final String outputPath;
  final int totalImages;
  final int processedImages;
  final int savedBytes;
  final Duration elapsed;
  final bool cancelled;

  Map<String, dynamic> toMap() {
    return {
      'outputPath': outputPath,
      'totalImages': totalImages,
      'processedImages': processedImages,
      'savedBytes': savedBytes,
      'elapsedMs': elapsed.inMilliseconds,
      'cancelled': cancelled,
    };
  }

  factory CompressionSummary.fromMap(Map<String, dynamic> map) {
    return CompressionSummary(
      outputPath: map['outputPath'] as String? ?? '',
      totalImages: map['totalImages'] as int? ?? 0,
      processedImages: map['processedImages'] as int? ?? 0,
      savedBytes: map['savedBytes'] as int? ?? 0,
      elapsed: Duration(milliseconds: map['elapsedMs'] as int? ?? 0),
      cancelled: map['cancelled'] as bool? ?? false,
    );
  }
}

class CompressionCancelled implements Exception {
  @override
  String toString() => 'Compression cancelled';
}

class EpubCompressor {
  Future<CompressionSummary> compressEpubInIsolate({
    required String inputPath,
    required String outputDir,
    required CompressionOptions options,
    CancellationToken? cancelToken,
    void Function(String message)? onLog,
    void Function(CompressionProgress progress)? onProgress,
  }) async {
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn<_IsolateParams>(
      _compressEpubIsolateEntry,
      _IsolateParams(
        sendPort: receivePort.sendPort,
        inputPath: inputPath,
        outputDir: outputDir,
        options: options.toMap(),
      ),
    );

    final completer = Completer<CompressionSummary>();
    SendPort? commandPort;
    void Function()? cancelListener;

    cancelListener = () {
      if (commandPort != null) {
        commandPort!.send({'type': 'cancel'});
      }
    };
    if (cancelToken != null && cancelListener != null) {
      cancelToken.addListener(cancelListener);
    }

    late StreamSubscription sub;
    sub = receivePort.listen((message) {
      if (message is! Map) return;
      switch (message['type']) {
        case 'ready':
          commandPort = message['commandPort'] as SendPort?;
          if (cancelToken?.isCancelled ?? false) {
            commandPort?.send({'type': 'cancel'});
          }
          break;
        case 'log':
          final text = message['message'] as String? ?? '';
          onLog?.call(text);
          break;
        case 'progress':
          final total = message['total'] as int? ?? 0;
          final processed = message['processed'] as int? ?? 0;
          final entry = message['entry'] as String? ?? '';
          onProgress?.call(CompressionProgress(
            totalImages: total,
            processedImages: processed,
            currentEntry: entry,
          ));
          break;
        case 'done':
          final summaryMap =
              (message['summary'] as Map?)?.cast<String, dynamic>() ?? {};
          completer.complete(CompressionSummary.fromMap(summaryMap));
          break;
        case 'cancelled':
          completer.completeError(CompressionCancelled());
          break;
        case 'error':
          completer
              .completeError(Exception(message['error'] ?? 'Unknown error'));
          break;
      }
    });

    try {
      final summary = await completer.future;
      return summary;
    } finally {
      if (cancelListener != null) {
        cancelToken?.removeListener(cancelListener);
      }
      isolate.kill(priority: Isolate.immediate);
      await sub.cancel();
      receivePort.close();
    }
  }

  Future<CompressionSummary> compressEpub({
    required String inputPath,
    required String outputDir,
    required CompressionOptions options,
    CancellationToken? cancelToken,
    void Function(String message)? onLog,
    void Function(CompressionProgress progress)? onProgress,
  }) async {
    return _compressEpubInternal(
      inputPath: inputPath,
      outputDir: outputDir,
      options: options,
      isCancelled: () => cancelToken?.isCancelled ?? false,
      onLog: onLog,
      onProgress: onProgress,
    );
  }

  bool _isImage(String ext) {
    return ext == '.jpg' || ext == '.jpeg' || ext == '.png' || ext == '.webp';
  }

  int _countImages(Archive archive) {
    return archive.files
        .where((f) => f.isFile && _isImage(p.extension(f.name).toLowerCase()))
        .length;
  }

  /// Decode, then re-encode [bytes] according to [options].
  ///
  /// Returns `(encodedBytes, convertedToJpg)`. A null first element means the
  /// bytes could not be decoded and the original should be kept. The second
  /// element is true only when a `.png` was actually re-encoded as JPEG (which
  /// the caller turns into a file rename plus reference update).
  Future<(List<int>?, bool)> _compressBytes(
    List<int> bytes,
    String ext,
    CompressionOptions options,
  ) async {
    // Run the CPU-heavy decode/encode work on a helper isolate
    // so the UI isolate stays responsive while compressing many images.
    return Isolate.run<(List<int>?, bool)>(() {
      final image = img.decodeImage(Uint8List.fromList(bytes));
      if (image == null) return (null, false);

      if (ext == '.png') {
        final transparent = _hasTransparency(image);
        if (options.convertPngToJpg &&
            (!transparent || options.convertTransparentPng)) {
          final source = transparent ? _flattenToWhite(image) : image;
          return (
            img.encodeJpg(source,
                quality: options.quality.clamp(1, 100),
                chroma: options.jpegChroma),
            true,
          );
        }
        return (
          img.encodePng(image, level: options.pngLevel.clamp(0, 9)),
          false,
        );
      }

      return (
        img.encodeJpg(image,
            quality: options.quality.clamp(1, 100), chroma: options.jpegChroma),
        false,
      );
    });
  }

  String _buildOutputPath({
    required String inputPath,
    required String outputDir,
  }) {
    final fileName = p.basename(inputPath);
    return p.join(outputDir, fileName);
  }

  ArchiveFile _rebuild(ArchiveFile src, String name, List<int> bytes) {
    return ArchiveFile(name, bytes.length, bytes)
      ..mode = src.mode
      ..lastModTime = src.lastModTime
      ..isFile = src.isFile
      ..isSymbolicLink = src.isSymbolicLink
      ..nameOfLinkedFile = src.nameOfLinkedFile;
  }

  Future<CompressionSummary> _compressEpubInternal({
    required String inputPath,
    required String outputDir,
    required CompressionOptions options,
    required bool Function() isCancelled,
    void Function(String message)? onLog,
    void Function(CompressionProgress progress)? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();
    if (isCancelled()) {
      throw CompressionCancelled();
    }

    final inputFile = File(inputPath);
    if (!await inputFile.exists()) {
      throw FileSystemException('EPUB file not found', inputPath);
    }

    final inputStream = InputFileStream(inputPath);
    final archive = ZipDecoder().decodeBuffer(
      inputStream,
      verify: false,
    );
    final totalImages = _countImages(archive);
    int processedImages = 0;
    int savedBytes = 0;

    Future<void> updateProgress(String entryName) async {
      processedImages = min(processedImages, totalImages);
      onProgress?.call(
        CompressionProgress(
          totalImages: totalImages,
          processedImages: processedImages,
          currentEntry: entryName,
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }

    // ---- Pass 1: plan. Decode + re-encode every image up front. ----
    // A PNG renamed to JPG must be done consistently everywhere, so the full
    // set of renames has to be known before any reference is rewritten in
    // pass 2. A rename is only planned when it is unambiguous: the source
    // basename is unique in the container and the destination name is free.
    final allPaths = <String>{};
    final imageBasenameCount = <String, int>{};
    for (final f in archive) {
      if (!f.isFile) continue;
      allPaths.add(f.name);
      if (_isImage(_zipExt(f.name))) {
        final base = _zipBasename(f.name);
        imageBasenameCount[base] = (imageBasenameCount[base] ?? 0) + 1;
      }
    }

    final convertedBytes = <String, List<int>>{}; // png path -> JPEG bytes
    final sameNameBytes = <String, List<int>>{}; // path -> recompressed bytes
    final renameByBasename = <String, String>{}; // 'cover.png' -> 'cover.jpg'
    final convertedNewBasenames = <String>{}; // 'cover.jpg'

    for (final f in archive) {
      if (isCancelled()) {
        throw CompressionCancelled();
      }
      if (!f.isFile) continue;

      final ext = _zipExt(f.name);
      if (!_isImage(ext)) continue;

      final originalBytes = f.content as List<int>;
      final originalSize = originalBytes.length;

      if (options.skipSmallImages && originalSize < options.minImageBytes) {
        processedImages++;
        await updateProgress(f.name);
        onLog?.call('Skip small image: ${f.name}');
        continue;
      }

      if (ext == '.webp') {
        processedImages++;
        await updateProgress(f.name);
        onLog?.call('Keep WebP: ${f.name}');
        continue;
      }

      var replaced = false;
      try {
        final (bytes, convertedToJpg) =
            await _compressBytes(originalBytes, ext, options);

        if (bytes == null) {
          onLog?.call('Keep original (undecodable): ${f.name}');
        } else if (bytes.length >= originalSize) {
          onLog?.call('Keep original: ${f.name}');
        } else if (convertedToJpg) {
          final newName = _toJpgPath(f.name);
          final oldBase = _zipBasename(f.name);
          final newBase = _zipBasename(newName);
          // Renaming relies on literal basename substitution in pass 2. A
          // name containing a space or % # ? is frequently percent-encoded
          // inside href/src, which substitution cannot match, so such files
          // are left untouched to avoid breaking the reference.
          final unsafeName = RegExp(r'''[% #?]''').hasMatch(oldBase);
          final ambiguous = unsafeName ||
              (imageBasenameCount[oldBase] ?? 0) > 1 ||
              (imageBasenameCount[newBase] ?? 0) > 0 ||
              allPaths.contains(newName);
          if (ambiguous) {
            // Cannot rewrite references safely; keep the original PNG.
            onLog?.call('Keep PNG (not safely renameable): ${f.name}');
          } else {
            convertedBytes[f.name] = bytes;
            renameByBasename[oldBase] = newBase;
            convertedNewBasenames.add(newBase);
            savedBytes += originalSize - bytes.length;
            onLog?.call(
              'Convert PNG->JPG: ${f.name} '
              '(${AppUtil.formatSize(originalSize)} -> ${AppUtil.formatSize(bytes.length)})',
            );
            replaced = true;
          }
        } else {
          sameNameBytes[f.name] = bytes;
          savedBytes += originalSize - bytes.length;
          onLog?.call(
            'Compressed: ${f.name} '
            '(${AppUtil.formatSize(originalSize)} -> ${AppUtil.formatSize(bytes.length)})',
          );
          replaced = true;
        }
      } catch (e) {
        onLog?.call('Compress failed, keep original: ${f.name}: $e');
      } finally {
        processedImages++;
        await updateProgress(f.name);
        // Free the decoded original once its replacement bytes are cached;
        // entries still needing their original are cleared after pass 2.
        if (replaced) {
          f.clear();
        }
      }
    }

    final outputPath = _buildOutputPath(
      inputPath: inputPath,
      outputDir: outputDir,
    );
    final outputFile = File(outputPath);
    await outputFile.parent.create(recursive: true);

    // ---- Pass 2: serialize. Write images (renaming where planned) and,
    // for text documents, rewrite every reference to a renamed image. ----
    final outputStream = OutputFileStream(outputPath);
    final encoder = ZipEncoder();

    try {
      encoder.startEncode(outputStream, level: Deflate.BEST_SPEED);

      for (final f in archive) {
        if (isCancelled()) {
          throw CompressionCancelled();
        }

        if (!f.isFile) {
          encoder.addFile(f, autoClose: false);
          continue;
        }

        final ext = _zipExt(f.name);

        if (_isImage(ext)) {
          if (convertedBytes.containsKey(f.name)) {
            encoder.addFile(
              _rebuild(f, _toJpgPath(f.name), convertedBytes[f.name]!),
              autoClose: true,
            );
          } else if (sameNameBytes.containsKey(f.name)) {
            encoder.addFile(
              _rebuild(f, f.name, sameNameBytes[f.name]!),
              autoClose: true,
            );
          } else {
            encoder.addFile(f, autoClose: false);
          }
          continue;
        }

        if (renameByBasename.isNotEmpty &&
            EpubReferenceRewriter.isTextRefFile(ext)) {
          try {
            final original = f.content as List<int>;
            final text = utf8.decode(original, allowMalformed: true);
            var rewritten = EpubReferenceRewriter.rewriteReferences(
              text,
              renameByBasename,
            );
            if (ext == '.opf') {
              rewritten = EpubReferenceRewriter.fixOpfMediaTypes(
                rewritten,
                convertedNewBasenames,
              );
            }
            if (rewritten != text) {
              encoder.addFile(
                _rebuild(f, f.name, utf8.encode(rewritten)),
                autoClose: true,
              );
              onLog?.call('Rewrote references: ${f.name}');
            } else {
              encoder.addFile(f, autoClose: false);
            }
          } catch (e) {
            onLog?.call('Reference rewrite failed, keep original: '
                '${f.name}: $e');
            encoder.addFile(f, autoClose: false);
          }
          continue;
        }

        encoder.addFile(f, autoClose: false);
      }

      if (isCancelled()) {
        throw CompressionCancelled();
      }
      encoder.endEncode();
    } finally {
      await outputStream.close();
      await inputStream.close();
      archive.clear();
    }

    stopwatch.stop();
    onLog?.call('Output completed: $outputPath');
    return CompressionSummary(
      outputPath: outputPath,
      totalImages: totalImages,
      processedImages: processedImages,
      savedBytes: savedBytes,
      elapsed: stopwatch.elapsed,
      cancelled: isCancelled(),
    );
  }
}

class _IsolateParams {
  _IsolateParams({
    required this.sendPort,
    required this.inputPath,
    required this.outputDir,
    required this.options,
  });

  final SendPort sendPort;
  final String inputPath;
  final String outputDir;
  final Map<String, dynamic> options;
}

Future<void> _compressEpubIsolateEntry(_IsolateParams params) async {
  final sendPort = params.sendPort;
  final cancelPort = ReceivePort();
  var cancelled = false;

  cancelPort.listen((message) {
    if (message is Map && message['type'] == 'cancel') {
      cancelled = true;
    }
  });

  sendPort.send({'type': 'ready', 'commandPort': cancelPort.sendPort});

  final compressor = EpubCompressor();
  try {
    final summary = await compressor._compressEpubInternal(
      inputPath: params.inputPath,
      outputDir: params.outputDir,
      options: CompressionOptions.fromMap(params.options),
      isCancelled: () => cancelled,
      onLog: (msg) => sendPort.send({'type': 'log', 'message': msg}),
      onProgress: (progress) => sendPort.send({
        'type': 'progress',
        'total': progress.totalImages,
        'processed': progress.processedImages,
        'entry': progress.currentEntry,
      }),
    );
    sendPort.send({'type': 'done', 'summary': summary.toMap()});
  } on CompressionCancelled {
    sendPort.send({'type': 'cancelled'});
  } catch (e) {
    sendPort.send({'type': 'error', 'error': e.toString()});
  } finally {
    cancelPort.close();
  }
}
