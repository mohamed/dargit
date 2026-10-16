// Merges lcov files from several test runs (any checkout location) into
// one, and prints line coverage per file and in total.
//
//   dart run tool/merge_lcov.dart <out.info> <in.info>...
//
// Exits with 1 when total coverage is below `--min=<percent>`.
import 'dart:io';

void main(List<String> args) {
  final min = args
      .where((a) => a.startsWith('--min='))
      .map((a) => double.parse(a.substring(6)))
      .firstOrNull;
  final files = args.where((a) => !a.startsWith('--')).toList();
  if (files.length < 2) {
    stderr.writeln('usage: merge_lcov.dart [--min=N] <out> <in>...');
    exit(2);
  }
  // lib-relative path -> line -> hits
  final hits = <String, Map<int, int>>{};
  for (final input in files.skip(1)) {
    Map<int, int>? current;
    for (final line in File(input).readAsLinesSync()) {
      if (line.startsWith('SF:')) {
        final path = line.substring(3).replaceAll(r'\', '/');
        final lib = path.lastIndexOf('/lib/');
        current = hits.putIfAbsent(
            lib < 0 ? path : path.substring(lib + 1), () => {});
      } else if (line.startsWith('DA:') && current != null) {
        final [n, h, ...] = line.substring(3).split(',');
        current.update(int.parse(n), (v) => v + int.parse(h),
            ifAbsent: () => int.parse(h));
      } else if (line == 'end_of_record') {
        current = null;
      }
    }
  }
  final out = StringBuffer();
  var total = 0, covered = 0;
  for (final path in hits.keys.toList()..sort()) {
    final lines = hits[path]!;
    final hit = lines.values.where((h) => h > 0).length;
    total += lines.length;
    covered += hit;
    out.writeln('SF:$path');
    for (final n in lines.keys.toList()..sort()) {
      out.writeln('DA:$n,${lines[n]}');
    }
    out
      ..writeln('LF:${lines.length}')
      ..writeln('LH:$hit')
      ..writeln('end_of_record');
    final missed = [
      for (final n in lines.keys.toList()..sort())
        if (lines[n] == 0) n
    ];
    stdout
        .writeln('${(100 * hit / lines.length).toStringAsFixed(1).padLeft(6)}%'
            '  $path${missed.isEmpty ? '' : '  missed: ${missed.join(', ')}'}');
  }
  File(files.first).writeAsStringSync(out.toString());
  final pct = 100 * covered / total;
  stdout.writeln('TOTAL ${pct.toStringAsFixed(2)}% ($covered/$total lines)');
  if (min != null && pct < min) exit(1);
}
