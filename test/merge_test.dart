import 'package:dartgit/src/merge.dart';
import 'package:test/test.dart';

void main() {
  const base = 'a\nb\nc\nd\ne\nf\n';

  test('non-overlapping edits merge', () {
    expect(merge3Text(base, 'A\nb\nc\nd\ne\nf\n', 'a\nb\nc\nd\ne\nF\n'),
        'A\nb\nc\nd\ne\nF\n');
    expect(merge3Text(base, 'a\nb\nx\nc\nd\ne\nf\n', 'a\nb\nc\nd\ne\nf\ny\n'),
        'a\nb\nx\nc\nd\ne\nf\ny\n');
    expect(
        merge3Text(base, 'b\nc\nd\ne\nf\n', 'a\nb\nc\nd\ne\n'), 'b\nc\nd\ne\n');
  });

  test('identical changes merge, one-sided changes win', () {
    expect(merge3Text(base, 'a\nB\nc\nd\ne\nf\n', 'a\nB\nc\nd\ne\nf\n'),
        'a\nB\nc\nd\ne\nf\n');
    expect(merge3Text(base, base, 'z\n'), 'z\n');
    expect(merge3Text(base, 'z\n', base), 'z\n');
  });

  test('overlapping edits conflict', () {
    expect(
        merge3Text(base, 'a\nX\nc\nd\ne\nf\n', 'a\nY\nc\nd\ne\nf\n'), isNull);
    expect(merge3Text(base, 'a\nb\nX\nd\ne\nf\n', 'a\nb\nc\nd\ne\nf\nmore\n'),
        'a\nb\nX\nd\ne\nf\nmore\n');
    // Insertions at the same place conflict.
    expect(merge3Text(base, 'a\nb\n1\nc\nd\ne\nf\n', 'a\nb\n2\nc\nd\ne\nf\n'),
        isNull);
  });

  test('missing final newline is preserved', () {
    expect(merge3Text('a\nb', 'A\nb', 'a\nb\nc'), 'A\nb\nc');
    expect(splitLines('x\ny'), ['x\n', 'y']);
  });
}
