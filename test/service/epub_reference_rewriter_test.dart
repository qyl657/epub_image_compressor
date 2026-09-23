import 'package:epub_image_compressor/service/epub_reference_rewriter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('rewriteReferences', () {
    const rename = {'cover.png': 'cover.jpg'};

    test('rewrites XHTML img src', () {
      const input = r"""<img src="images/cover.png" alt="c"/>""";
      const expected = r"""<img src="images/cover.jpg" alt="c"/>""";
      expect(EpubReferenceRewriter.rewriteReferences(input, rename), expected);
    });

    test('rewrites SVG xlink:href', () {
      const input = r"""<image xlink:href="../images/cover.png" width="10"/>""";
      const expected =
          r"""<image xlink:href="../images/cover.jpg" width="10"/>""";
      expect(EpubReferenceRewriter.rewriteReferences(input, rename), expected);
    });

    test('rewrites unquoted CSS url()', () {
      const input = r"""body { background: url(images/cover.png) center; }""";
      const expected =
          r"""body { background: url(images/cover.jpg) center; }""";
      expect(EpubReferenceRewriter.rewriteReferences(input, rename), expected);
    });

    test('rewrites quoted CSS url("...")', () {
      const input = r""".x { background: url("images/cover.png"); }""";
      const expected = r""".x { background: url("images/cover.jpg"); }""";
      expect(EpubReferenceRewriter.rewriteReferences(input, rename), expected);
    });

    test('handles srcset without touching unrelated files', () {
      const input = r'''srcset="images/cover.png 1x, images/hi.png 2x"''';
      const expected = r'''srcset="images/cover.jpg 1x, images/hi.png 2x"''';
      expect(EpubReferenceRewriter.rewriteReferences(input, rename), expected);
    });

    test('does not rewrite a similarly named file', () {
      const input = r"""<img src="images/oldcover.png"/>""";
      expect(EpubReferenceRewriter.rewriteReferences(input, rename), input);
    });

    test('does not rewrite visible text inside an element', () {
      // "<title>cover.png</title>" is preceded by '>' which is not a
      // reference delimiter, so the prose is left untouched.
      const input = r"""<title>cover.png</title>""";
      expect(EpubReferenceRewriter.rewriteReferences(input, rename), input);
    });

    test('applies multiple renames', () {
      const many = {'a.png': 'a.jpg', 'b.png': 'b.jpg'};
      const input = r"""<a href="a.png"><img src="b.png"/></a>""";
      const expected = r"""<a href="a.jpg"><img src="b.jpg"/></a>""";
      expect(EpubReferenceRewriter.rewriteReferences(input, many), expected);
    });

    test('empty map returns input unchanged', () {
      const input = r"""<img src="images/cover.png"/>""";
      expect(EpubReferenceRewriter.rewriteReferences(input, const {}), input);
    });
  });

  group('fixOpfMediaTypes', () {
    test('flips media-type only for converted items', () {
      const input = r'''
<manifest>
  <item id="c" href="images/cover.jpg" media-type="image/png"/>
  <item id="p" href="images/pic.png" media-type="image/png"/>
</manifest>''';
      final out = EpubReferenceRewriter.fixOpfMediaTypes(input, {'cover.jpg'});
      expect(out, contains('href="images/cover.jpg" media-type="image/jpeg"'));
      expect(out, contains('href="images/pic.png" media-type="image/png"'));
    });

    test('combined rewrite + media-type fix produces a valid item', () {
      const opf =
          r'''<item id="c" href="images/cover.png" media-type="image/png"/>''';
      var out = EpubReferenceRewriter.rewriteReferences(
          opf, {'cover.png': 'cover.jpg'});
      out = EpubReferenceRewriter.fixOpfMediaTypes(out, {'cover.jpg'});
      expect(out,
          r'''<item id="c" href="images/cover.jpg" media-type="image/jpeg"/>''');
    });

    test('empty conversion set returns input unchanged', () {
      const input = r'''<item id="c" href="a.png" media-type="image/png"/>''';
      expect(
        EpubReferenceRewriter.fixOpfMediaTypes(input, const <String>{}),
        input,
      );
    });
  });

  group('isTextRefFile', () {
    test('classifies reference-bearing extensions', () {
      expect(EpubReferenceRewriter.isTextRefFile('.opf'), isTrue);
      expect(EpubReferenceRewriter.isTextRefFile('.xhtml'), isTrue);
      expect(EpubReferenceRewriter.isTextRefFile('.CSS'), isTrue);
      expect(EpubReferenceRewriter.isTextRefFile('.svg'), isTrue);
      expect(EpubReferenceRewriter.isTextRefFile('.jpg'), isFalse);
      expect(EpubReferenceRewriter.isTextRefFile(''), isFalse);
    });
  });
}
