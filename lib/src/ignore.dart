/// `.gitignore` matching (gitignore(5), with git's wildmatch rules).
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
      final (cls, next) = _bracket(glob, i);
      // Like wildmatch: an unclosed bracket makes the pattern match nothing.
      if (cls == null) return '(?!)';
      sb.write(cls);
      i = next;
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

const _posixClasses = {
  'alnum': 'a-zA-Z0-9',
  'alpha': 'a-zA-Z',
  'blank': r' \t',
  'cntrl': r'\x00-\x1f\x7f',
  'digit': '0-9',
  'graph': r'!-~',
  'lower': 'a-z',
  'print': r' -~',
  'punct': r'!-/:-@\[-`{-~',
  'space': r' \t\n\r\f\v',
  'upper': 'A-Z',
  'xdigit': '0-9a-fA-F',
};

/// The bracket expression starting at `glob[start] == '['`, as git's
/// wildmatch reads it, converted to a regex (never matching `/`), with the
/// index after it; null when the bracket is not closed.
(String?, int) _bracket(String glob, int start) {
  var i = start + 1;
  var negate = false;
  if (i < glob.length && (glob[i] == '!' || glob[i] == '^')) {
    negate = true;
    i++;
  }
  String esc(int code) => '\\u${code.toRadixString(16).padLeft(4, '0')}';
  final parts = <String>[];
  var first = true;
  while (true) {
    if (i >= glob.length) return (null, i);
    var c = glob[i];
    if (c == ']' && !first) break;
    first = false;
    if (c == '[' && i + 1 < glob.length && glob[i + 1] == ':') {
      final close = glob.indexOf(':]', i + 2);
      if (close < 0) return (null, i);
      final cls = _posixClasses[glob.substring(i + 2, close)];
      if (cls == null) return (null, i); // wildmatch aborts on unknown names
      parts.add(cls);
      i = close + 2;
      continue;
    }
    if (c == r'\') {
      if (++i >= glob.length) return (null, i);
      c = glob[i];
    }
    i++;
    if (i + 1 < glob.length && glob[i] == '-' && glob[i + 1] != ']') {
      var hi = glob[i + 1];
      i += 2;
      if (hi == r'\') {
        if (i >= glob.length) return (null, i);
        hi = glob[i++];
      }
      // Like wildmatch, a reversed range matches just its first character.
      parts.add(hi.codeUnitAt(0) >= c.codeUnitAt(0)
          ? '${esc(c.codeUnitAt(0))}-${esc(hi.codeUnitAt(0))}'
          : esc(c.codeUnitAt(0)));
      continue;
    }
    parts.add(esc(c.codeUnitAt(0)));
  }
  final body = parts.join();
  return (negate ? '[^/$body]' : '(?!/)[$body]', i + 1);
}
