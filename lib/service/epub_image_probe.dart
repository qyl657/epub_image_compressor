import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

/// Annex-K 标准亮度量化表，用于从源图 DQT 反推 JPEG 质量档。
const _stdLuma = <int>[
  16, 11, 10, 16, 24, 40, 51, 61, //
  12, 12, 14, 19, 26, 58, 60, 55,
  14, 13, 16, 24, 40, 57, 69, 56,
  14, 17, 22, 29, 51, 87, 80, 62,
  18, 22, 37, 56, 68, 109, 103, 77,
  24, 35, 61, 85, 106, 120, 113, 85,
  49, 64, 78, 87, 103, 121, 120, 101,
  72, 92, 95, 98, 112, 100, 103, 99,
];

/// 源图概况粗扫结果。只读 marker，不做全图解码，因此大文件也很快。
class SourceReport {
  const SourceReport({
    this.error = '',
    this.imageCount = 0,
    this.countByExt = const {},
    this.bytesByExt = const {},
    this.scanned = 0,
    this.jpeg420 = 0,
    this.jpeg444 = 0,
    this.jpegUnknown = 0,
    this.qualities = const [],
    this.pngWithAlpha = 0,
    this.pngOpaque = 0,
    this.maxImageBytes = 0,
  });

  final String error;
  final int imageCount;
  final Map<String, int> countByExt;
  final Map<String, int> bytesByExt;
  final int scanned;
  final int jpeg420;
  final int jpeg444;
  final int jpegUnknown;
  final List<int> qualities;
  final int pngWithAlpha;
  final int pngOpaque;
  final int maxImageBytes;

  bool get ok => error.isEmpty;

  /// 采样质量的中位数；无 JPEG 样本时为 null。
  int? get medianQuality =>
      qualities.isEmpty ? null : qualities[qualities.length ~/ 2];

  /// 体积占比最大的扩展名。
  String get dominantExt {
    var best = '', bestBytes = -1;
    bytesByExt.forEach((ext, bytes) {
      if (bytes > bestBytes) {
        bestBytes = bytes;
        best = ext;
      }
    });
    return best;
  }

  int get totalImageBytes => bytesByExt.values.fold(0, (sum, b) => sum + b);

  static String formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  String describe() {
    if (!ok) return '扫描失败：$error';
    if (imageCount == 0) return '未发现可压缩图片。';

    final parts = <String>[];
    final sortedExts = bytesByExt.keys.toList()
      ..sort((a, b) => (bytesByExt[b] ?? 0).compareTo(bytesByExt[a] ?? 0));
    final share = <String>[];
    final total = totalImageBytes == 0 ? 1 : totalImageBytes;
    for (final ext in sortedExts) {
      share.add(
          '$ext ${countByExt[ext]}张/${((bytesByExt[ext] ?? 0) * 100 / total).round()}%');
    }
    parts.add(
        '共 $imageCount 张(${formatBytes(totalImageBytes)})：${share.join('、')}');

    if (scanned > 0) {
      final q = medianQuality;
      final chroma = '$jpeg420 张 4:2:0、$jpeg444 张 4:4:4';
      parts.add('抽样 $scanned 张：JPEG 色度 $chroma'
          '${q == null ? '' : '，源质量 q≈$q（区间 ${qualities.first}~${qualities.last}）'}');
      if (pngWithAlpha + pngOpaque > 0) {
        parts.add('PNG 带透明 $pngWithAlpha 张、不透明 $pngOpaque 张');
      }
      parts.add('单张最大 ${formatBytes(maxImageBytes)}');
    }

    if (dominantExt == '.png') {
      parts.add('提示：体积主要在 PNG，开「PNG转JPG」收益最大。');
    } else if (dominantExt == '.jpg' || dominantExt == '.jpeg') {
      parts.add('提示：源图已是 JPEG，只能靠降质量；若设定质量 ≥ 源质量会大量'
          '「Keep original」。');
    }
    return parts.join('\n');
  }

  Map<String, dynamic> toMap() => {
        'error': error,
        'imageCount': imageCount,
        'countByExt': countByExt,
        'bytesByExt': bytesByExt,
        'scanned': scanned,
        'jpeg420': jpeg420,
        'jpeg444': jpeg444,
        'jpegUnknown': jpegUnknown,
        'qualities': qualities,
        'pngWithAlpha': pngWithAlpha,
        'pngOpaque': pngOpaque,
        'maxImageBytes': maxImageBytes,
      };

  factory SourceReport.fromMap(Map<String, dynamic> map) => SourceReport(
        error: map['error'] as String? ?? '',
        imageCount: map['imageCount'] as int? ?? 0,
        countByExt: (map['countByExt'] as Map? ?? {}).cast<String, int>(),
        bytesByExt: (map['bytesByExt'] as Map? ?? {}).cast<String, int>(),
        scanned: map['scanned'] as int? ?? 0,
        jpeg420: map['jpeg420'] as int? ?? 0,
        jpeg444: map['jpeg444'] as int? ?? 0,
        jpegUnknown: map['jpegUnknown'] as int? ?? 0,
        qualities: (map['qualities'] as List? ?? []).cast<int>(),
        pngWithAlpha: map['pngWithAlpha'] as int? ?? 0,
        pngOpaque: map['pngOpaque'] as int? ?? 0,
        maxImageBytes: map['maxImageBytes'] as int? ?? 0,
      );
}

/// 解析 JPEG 的 SOF 采样因子与首个 DQT 亮度表。
JpegMarkers parseJpegMarkers(Uint8List b) {
  var sampling = '';
  List<int>? luma;
  var i = 2;
  while (i < b.length - 4) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = b[i + 1];
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    final len = (b[i + 2] << 8) | b[i + 3];
    if (marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC) {
      final ncomp = b[i + 9];
      final factors = <String>[];
      for (var c = 0; c < ncomp; c++) {
        final hv = b[i + 11 + c * 3];
        factors.add('${(hv >> 4) & 0xF}x${hv & 0xF}');
      }
      sampling = factors.join(' ');
    } else if (marker == 0xDB && luma == null) {
      var p = i + 4;
      while (p + 64 <= i + 2 + len && luma == null) {
        final precision = b[p] >> 4;
        final step = precision == 0 ? 1 : 2;
        final table = <int>[];
        for (var k = 0; k < 64; k++) {
          table.add(precision == 0
              ? b[p + 1 + k]
              : b[p + 1 + k * 2] | (b[p + 2 + k * 2] << 8));
        }
        luma = table;
        p += 1 + 64 * step;
      }
    }
    i += 2 + len;
  }
  return JpegMarkers(sampling: sampling, lumaTable: luma);
}

class JpegMarkers {
  JpegMarkers({required this.sampling, required this.lumaTable});
  final String sampling;
  final List<int>? lumaTable;

  /// 首分量水平采样因子 2 表示色度被减半存储，即 4:2:0。
  bool get is420 => sampling.startsWith('2x2');
  bool get is444 => sampling.isNotEmpty && sampling.startsWith('1x1');
}

/// 把源图亮度表与标准表在 1..100 各质量下逐一比对，取误差最小的档位。
int estimateJpegQuality(List<int> table) {
  var best = -1, bestErr = 1 << 30;
  for (var q = 1; q <= 100; q++) {
    final scale = q < 50 ? (5000 ~/ q) : (200 - 2 * q);
    var err = 0;
    for (var k = 0; k < 64; k++) {
      final scaled = ((_stdLuma[k] * scale + 50) / 100).round().clamp(1, 255);
      err += (scaled - table[k]).abs();
    }
    if (err < bestErr) {
      bestErr = err;
      best = q;
    }
  }
  return best;
}

/// PNG IHDR：colorType 6=RGBA、4=灰度+alpha 视为带透明。
bool pngHasAlpha(Uint8List b) {
  if (b.length < 25) return false;
  if (!(b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47)) {
    return false;
  }
  final colorType = b[25];
  return colorType == 6 || colorType == 4;
}

class EpubImageProbe {
  /// 在后台 isolate 里粗扫 [inputPath]，均匀抽取 [samples] 张图读 marker。
  static Future<SourceReport> probe(String inputPath, {int samples = 8}) async {
    final map = await Isolate.run<Map<String, dynamic>>(
      () => _probeSync(inputPath, samples),
    );
    return SourceReport.fromMap(map);
  }

  static Map<String, dynamic> _probeSync(String inputPath, int samples) {
    try {
      final file = File(inputPath);
      if (!file.existsSync()) {
        return const SourceReport(error: '文件不存在').toMap();
      }
      final stream = InputFileStream(inputPath);
      try {
        final archive = ZipDecoder().decodeBuffer(stream, verify: false);
        final counts = <String, int>{};
        final bytes = <String, int>{};
        final candidates = <ArchiveFile>[];

        for (final f in archive) {
          if (!f.isFile) continue;
          final ext = _extOf(f.name);
          if (ext != '.jpg' && ext != '.jpeg' && ext != '.png') continue;
          counts[ext] = (counts[ext] ?? 0) + 1;
          bytes[ext] = (bytes[ext] ?? 0) + f.size;
          candidates.add(f);
        }

        final picked = _evenSpread(candidates, samples);
        var jpeg420 = 0, jpeg444 = 0, jpegUnknown = 0;
        var pngAlpha = 0, pngOpaque = 0, maxBytes = 0;
        final qualities = <int>[];

        for (final f in picked) {
          final content = Uint8List.fromList(f.content as List<int>);
          maxBytes = content.length > maxBytes ? content.length : maxBytes;
          if (_extOf(f.name) == '.png') {
            if (pngHasAlpha(content)) {
              pngAlpha++;
            } else {
              pngOpaque++;
            }
            continue;
          }
          final markers = parseJpegMarkers(content);
          if (markers.is420) {
            jpeg420++;
          } else if (markers.is444) {
            jpeg444++;
          } else {
            jpegUnknown++;
          }
          final table = markers.lumaTable;
          if (table != null) qualities.add(estimateJpegQuality(table));
        }

        qualities.sort();
        return SourceReport(
          imageCount: counts.values.fold(0, (s, v) => s + v),
          countByExt: counts,
          bytesByExt: bytes,
          scanned: picked.length,
          jpeg420: jpeg420,
          jpeg444: jpeg444,
          jpegUnknown: jpegUnknown,
          qualities: qualities,
          pngWithAlpha: pngAlpha,
          pngOpaque: pngOpaque,
          maxImageBytes: maxBytes,
        ).toMap();
      } finally {
        stream.close();
      }
    } catch (e) {
      return SourceReport(error: '$e').toMap();
    }
  }
}

List<ArchiveFile> _evenSpread(List<ArchiveFile> all, int samples) {
  if (all.isEmpty || samples <= 0) return const [];
  if (samples >= all.length) return List.of(all);
  final picked = <ArchiveFile>{};
  final step = all.length / samples;
  for (var i = 0; i < samples; i++) {
    picked.add(all[(i * step).round().clamp(0, all.length - 1)]);
  }
  return picked.toList();
}

String _extOf(String path) {
  final dot = path.lastIndexOf('.');
  final slash = path.lastIndexOf('/');
  return (dot >= 0 && dot > slash) ? path.substring(dot).toLowerCase() : '';
}
