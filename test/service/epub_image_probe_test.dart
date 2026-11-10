import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:epub_image_compressor/service/epub_image_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 造一个只含图片条目的 zip，当作 EPUB 容器结构的最小替身。
Uint8List buildZip(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

img.Image _rgb() {
  final image = img.Image(width: 32, height: 32, numChannels: 3);
  for (var y = 0; y < 32; y++) {
    for (var x = 0; x < 32; x++) {
      image.setPixelRgb(x, y, (x * 8) % 256, (y * 8) % 256, 128);
    }
  }
  return image;
}

img.Image _rgba() {
  final image = img.Image(width: 32, height: 32, numChannels: 4);
  for (var y = 0; y < 32; y++) {
    for (var x = 0; x < 32; x++) {
      image.setPixelRgba(x, y, 200, 30, 30, y < 16 ? 255 : 40);
    }
  }
  return image;
}

void main() {
  group('parseJpegMarkers', () {
    test('识别 4:2:0 与 4:4:4', () {
      final src = _rgb();
      final m420 = parseJpegMarkers(Uint8List.fromList(
          img.encodeJpg(src, quality: 60, chroma: img.JpegChroma.yuv420)));
      final m444 = parseJpegMarkers(Uint8List.fromList(
          img.encodeJpg(src, quality: 60, chroma: img.JpegChroma.yuv444)));

      expect(m420.sampling, '2x2 1x1 1x1');
      expect(m420.is420, isTrue);
      expect(m444.is420, isFalse);
      expect(m444.is444, isTrue);
    });

    test('从量化表反推的质量接近编码时的设定值', () {
      final bytes = Uint8List.fromList(
          img.encodeJpg(_rgb(), quality: 60, chroma: img.JpegChroma.yuv420));
      final quality = estimateJpegQuality(parseJpegMarkers(bytes).lumaTable!);

      expect(quality, closeTo(60, 6));
    });
  });

  group('pngHasAlpha', () {
    test('区分带 alpha 与不透明的 PNG', () {
      final withAlpha = Uint8List.fromList(img.encodePng(_rgba()));
      final opaque = Uint8List.fromList(img.encodePng(_rgb()));

      expect(pngHasAlpha(withAlpha), isTrue);
      expect(pngHasAlpha(opaque), isFalse);
    });

    test('非 PNG 字节返回 false', () {
      expect(pngHasAlpha(Uint8List.fromList([1, 2, 3, 4, 5])), isFalse);
    });
  });

  group('EpubImageProbe.probe', () {
    late Directory tmp;
    late String epubPath;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('epub_probe_test');
      final jpeg420 = Uint8List.fromList(
          img.encodeJpg(_rgb(), quality: 60, chroma: img.JpegChroma.yuv420));
      final jpeg444 = Uint8List.fromList(
          img.encodeJpg(_rgb(), quality: 60, chroma: img.JpegChroma.yuv444));
      final pngAlpha = Uint8List.fromList(img.encodePng(_rgba()));
      final pngOpaque = Uint8List.fromList(img.encodePng(_rgb()));
      epubPath = '${tmp.path}/sample.epub';
      File(epubPath).writeAsBytesSync(buildZip({
        'mimetype': 'application/epub+zip'.codeUnits,
        'META-INF/container.xml': '<container/>'.codeUnits,
        'OEBPS/content.opf': '<package/>'.codeUnits,
        'OEBPS/Images/420.jpg': jpeg420,
        'OEBPS/Images/444.jpg': jpeg444,
        'OEBPS/Images/alpha.png': pngAlpha,
        'OEBPS/Images/opaque.png': pngOpaque,
      }));
    });

    tearDownAll(() async => tmp.delete(recursive: true));

    test('按扩展名统计张数，且只看图片条目', () async {
      final report = await EpubImageProbe.probe(epubPath, samples: 100);

      expect(report.ok, isTrue, reason: report.error);
      expect(report.imageCount, 4);
      expect(report.countByExt['.jpg'], 2);
      expect(report.countByExt['.png'], 2);
      expect(report.bytesByExt['.jpg'], greaterThan(0));
      expect(report.dominantExt, isNotNull);
    });

    test('采样足够时同时认出 4:2:0、4:4:4、透明与不透明 PNG', () async {
      final report = await EpubImageProbe.probe(epubPath, samples: 8);

      expect(report.scanned, 4);
      expect(report.jpeg420, 1);
      expect(report.jpeg444, 1);
      expect(report.pngWithAlpha, 1);
      expect(report.pngOpaque, 1);
      expect(report.medianQuality, closeTo(60, 6));
    });

    test('采样张数小于图片数时按均匀抽样的条数扫描', () async {
      final report = await EpubImageProbe.probe(epubPath, samples: 2);

      expect(report.scanned, 2);
      expect(report.imageCount, 4);
    });

    test('describe 汇总张数与占比', () async {
      final report = await EpubImageProbe.probe(epubPath, samples: 8);
      final text = report.describe();

      expect(text, contains('共 4 张'));
      expect(text, contains('4:2:0'));
    });

    test('容器里没有图片时报告无可压缩图片', () async {
      final noImages = '${tmp.path}/empty.epub';
      File(noImages).writeAsBytesSync(buildZip({
        'mimetype': 'application/epub+zip'.codeUnits,
      }));

      final report = await EpubImageProbe.probe(noImages);

      expect(report.imageCount, 0);
      expect(report.describe(), contains('未发现可压缩图片'));
    });

    test('文件不存在时返回错误而不是抛出', () async {
      final report = await EpubImageProbe.probe('${tmp.path}/missing.epub');

      expect(report.ok, isFalse);
      expect(report.describe(), contains('扫描失败'));
    });
  });
}
