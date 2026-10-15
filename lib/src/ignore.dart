/// `.gitignore` matching (the commonly used subset of gitignore(5)).
library;

class _Rule {
  _Rule(this.base, this.re, {required this.negate, required this.dirOnly});
  final String base; // directory of the .gitignore ('' for root), no slash
  final RegExp re;
  final bool negate;
  final bool dirOnly;
}

class IgnoreRules {
  final List<_Rule> _rules = [];

  /// Adds the patterns of a `.gitignore` located in [base] ('' = root).
  void addPatterns(String base, String content) {
    for (var line in content.split('\n')) {
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      if (line.isEmpty || line.startsWith('#')) continue;
      // Trailing unescaped spaces are ignored.
      while (line.endsWith(' ') && !line.endsWith(r'\ ')) {
        line = line.substring(0, line.length - 1);
      }
      if (line.isEmpty) continue;
      var negate = false;
      if (line.startsWith('!')) {
        negate = true;
        line = line.substring(1);
      } else if (line.startsWith(r'\!') || line.startsWith(r'\#')) {
        line = line.substring(1);
      }
      var dirOnly = false;
      if (line.endsWith('/')) {
        dirOnly = true;
        line = line.substring(0, line.length - 1);
      }
      if (line.isEmpty) continue;
      final anchored = line.contains('/');
      if (line.startsWith('/')) line = line.substring(1);
      final body = _globToRegex(line);
      final re = RegExp(anchored ? '^$body\$' : '^(?:.*/)?$body\$');
      _rules.add(_Rule(base, re, negate: negate, dirOnly: dirOnly));
    }
  }

  /// Whether [path] (repository-relative, `/`-separated) is ignored.
  /// Parent directories must be checked by the caller while walking.
  bool isIgnored(String path, {required bool isDir}) {
    var ignored = false;
    for (final r in _rules) {
      if (r.dirOnly && !isDir) continue;
      String rel;
      if (r.base.isEmpty) {
        rel = path;
      } else if (path.startsWith('${r.base}/')) {
        rel = path.substring(r.base.length + 1);
      } else {
        continue;
      }
      if (r.re.hasMatch(rel)) ignored = !r.negate;
    }
    return ignored;
  }
}

String _globToRegex(String glob) {
  final sb = StringBuffer();
  var i = 0;
  while (i < glob.length) {
    final c = glob[i];
    if (c == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        final atStart = i == 0 || glob[i - 1] == '/';
        final atEnd = i + 2 == glob.length || glob[i + 2] == '/';
        if (atStart && atEnd) {
          if (i + 2 == glob.length) {
            sb.write('.*');
            i += 2;
          } else {
            sb.write('(?:.*/)?');
            i += 3;
          }
          continue;
        }
      }
      sb.write('[^/]*');
      i++;
    } else if (c == '?') {
      sb.write('[^/]');
      i++;
    } else if (c == '[') {
      final close = glob.indexOf(']', i + 2);
      if (close < 0) {
        sb.write(r'\[');
        i++;
        continue;
      }
      var cls = glob.substring(i + 1, close);
      if (cls.startsWith('!')) cls = '^${cls.substring(1)}';
      sb.write('[${cls.replaceAll(r'\', r'\\')}]');
      i = close + 1;
    } else if (c == r'\' && i + 1 < glob.length) {
      sb.write(RegExp.escape(glob[i + 1]));
      i += 2;
    } else {
      sb.write(RegExp.escape(c));
      i++;
    }
  }
  return sb.toString();
}
