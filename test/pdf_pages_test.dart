// Page-by-page PDF text (features/search/pdf_text.dart: pdfPageTexts): pages
// come out in the document's own page order, however the objects are laid out
// in the file, and nothing is guessed when the page tree cannot be read.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_application_1/features/search/pdf_text.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List pdf(List<String> objects) => Uint8List.fromList(
  latin1.encode('%PDF-1.4\n${objects.join('\n')}\n%%EOF\n'),
);

String content(int n, String text) {
  final body = 'BT /F1 12 Tf ($text) Tj ET';
  return '$n 0 obj\n<< /Length ${body.length} >>\nstream\n$body\nendstream\nendobj';
}

void main() {
  test('pages come out in page order even when the file stores them shuffled', () {
    final bytes = pdf([
      // The content of page 3 is stored first, page 1 last.
      content(8, 'third page about zebras'),
      content(7, 'second page about quasars'),
      content(6, 'first page about tomatoes'),
      '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj',
      '2 0 obj\n<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>\nendobj',
      '3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 6 0 R >>\nendobj',
      '4 0 obj\n<< /Type /Page /Parent 2 0 R /Contents [7 0 R] >>\nendobj',
      '5 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 8 0 R >>\nendobj',
    ]);
    final pages = pdfPageTexts(bytes)!;
    expect(pages, hasLength(3));
    expect(pages[0], contains('tomatoes'));
    expect(pages[1], contains('quasars'));
    expect(pages[2], contains('zebras'));
  });

  test('a nested page tree is followed in order', () {
    final bytes = pdf([
      '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj',
      '2 0 obj\n<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 3 >>\nendobj',
      '3 0 obj\n<< /Type /Pages /Parent 2 0 R /Kids [4 0 R 5 0 R] >>\nendobj',
      '4 0 obj\n<< /Type /Page /Parent 3 0 R /Contents 7 0 R >>\nendobj',
      '5 0 obj\n<< /Type /Page /Parent 3 0 R /Contents 8 0 R >>\nendobj',
      '6 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 9 0 R >>\nendobj',
      content(7, 'alpha'),
      content(8, 'beta'),
      content(9, 'gamma'),
    ]);
    final pages = pdfPageTexts(bytes)!;
    expect([for (final p in pages) p.trim()], ['alpha', 'beta', 'gamma']);
  });

  test('a page without text is an empty page, so numbers stay right', () {
    final bytes = pdf([
      '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj',
      '2 0 obj\n<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>\nendobj',
      '3 0 obj\n<< /Type /Page /Parent 2 0 R >>\nendobj',
      '4 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 5 0 R >>\nendobj',
      content(5, 'only the second page has words'),
    ]);
    final pages = pdfPageTexts(bytes)!;
    expect(pages[0], '');
    expect(pages[1], contains('second page'));
  });

  test('no readable page tree means no page information, not a guess', () {
    expect(pdfPageTexts(Uint8List.fromList(latin1.encode('hello'))), isNull);
    expect(pdfPageTexts(pdf([content(1, 'text but no pages object')])), isNull);
    // Pages exist but their content is somewhere unreadable.
    final hidden = pdf([
      '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj',
      '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj',
      '3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 40 0 R >>\nendobj',
    ]);
    expect(pdfPageTexts(hidden), isNull);
  });

  test('a loop in the page tree does not hang', () {
    final bytes = pdf([
      '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj',
      '2 0 obj\n<< /Type /Pages /Kids [3 0 R] >>\nendobj',
      '3 0 obj\n<< /Type /Pages /Parent 2 0 R /Kids [2 0 R] >>\nendobj',
    ]);
    expect(pdfPageTexts(bytes), isNull);
  });

  test('the whole-document text is unchanged', () {
    final bytes = pdf([
      content(6, 'first page about tomatoes'),
      '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj',
      '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj',
      '3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 6 0 R >>\nendobj',
    ]);
    expect(pdfText(bytes), contains('tomatoes'));
  });
}
