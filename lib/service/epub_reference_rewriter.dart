/// Helpers that keep an EPUB valid after its image resources are renamed
/// (for example PNG -> JPG).
///
/// When a resource file inside the EPUB container changes its name, every
/// place that points at it must change too, otherwise the book breaks:
///   * the OPF `<manifest>` item `href` and its `media-type`;
///   * `<img src>`, `<image xlink:href>` and other references in XHTML;
///   * `url(...)` in CSS and `xlink:href` in SVG.
///
/// The reference rewriting matches a resource *basename* (e.g. `cover.png`)
/// only where it appears as a complete reference token, so a similarly named
/// file such as `oldcover.png` is never touched.
class EpubReferenceRewriter {
  EpubReferenceRewriter._();

  /// Container entries with these extensions may contain image references
  /// and are therefore rewritten as text. Binary files and `mimetype` are
  /// never modified.
  static const Set<String> textRefExtensions = <String>{
    '.opf',
    '.ncx',
    '.xhtml',
    '.html',
    '.htm',
    '.css',
    '.svg',
    '.xml',
  };

  static bool isTextRefFile(String ext) =>
      textRefExtensions.contains(ext.toLowerCase());

  /// Rewrite references across an XML/HTML/CSS/SVG text document.
  ///
  /// [renameByBasename] maps an old basename to its new basename
  /// (e.g. `{'cover.png': 'cover.jpg'}`). The caller guarantees basenames
  /// are unique within the EPUB, so a plain basename substitution is safe.
  static String rewriteReferences(
    String text,
    Map<String, String> renameByBasename,
  ) {
    if (renameByBasename.isEmpty || text.isEmpty) return text;
    var result = text;
    for (final entry in renameByBasename.entries) {
      // Zero-width assertions on both sides keep the delimiters in place, so
      // adjacent references separated by a single character are all replaced.
      // The delimiter set covers every real reference context (after a quote,
      // equals, path separator, opening paren or separator) while deliberately
      // excluding angle brackets so visible text like "<title>cover.png</title>"
      // is not rewritten.
      final re = RegExp(
        r"""(?<=[\s"'(/=,])""" +
            RegExp.escape(entry.key) +
            r"""(?=[\s"')=,;])""",
      );
      result = result.replaceAllMapped(re, (_) => entry.value);
    }
    return result;
  }

  /// Flip `media-type="image/png"` to `"image/jpeg"` on OPF `<item>` elements
  /// whose (already rewritten) `href` now ends with one of
  /// [convertedNewBasenames]. Items that still reference a genuine PNG are
  /// left untouched.
  static String fixOpfMediaTypes(
    String opfText,
    Set<String> convertedNewBasenames,
  ) {
    if (convertedNewBasenames.isEmpty || opfText.isEmpty) return opfText;
    return opfText.replaceAllMapped(
      RegExp(r'<item\b[^>]*>', dotAll: true),
      (match) {
        final tag = match.group(0)!;
        final href = RegExp(r'''href\s*=\s*["']([^"']*)["']''')
            .firstMatch(tag)
            ?.group(1);
        if (href == null || href.isEmpty) return tag;
        final basename = href.substring(href.lastIndexOf('/') + 1);
        if (!convertedNewBasenames.contains(basename)) return tag;
        return tag.replaceAllMapped(
          RegExp(r'''(media-type\s*=\s*)["']image/png["']'''),
          (mm) => '${mm.group(1)}"image/jpeg"',
        );
      },
    );
  }
}
