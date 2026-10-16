import 'dart:io';

import 'util.dart';

/// Minimal reader/writer for `.git/config` that preserves unknown content.
class GitConfig {
  GitConfig(this.path, this._lines);

  factory GitConfig.load(String path) {
    final f = File(path);
    return GitConfig(path, f.existsSync() ? f.readAsLinesSync() : <String>[]);
  }

  final String path;
  final List<String> _lines;

  static final _sectionRe =
      RegExp(r'^\s*\[\s*([A-Za-z0-9.-]+)(?:\s+"((?:[^"\\]|\\.)*)")?\s*\]');
  static final _keyRe = RegExp(r'^\s*([A-Za-z][A-Za-z0-9-]*)\s*(?:=\s*(.*))?$');

  static String _sectionKey(String section, String? sub) => sub == null
      ? section.toLowerCase()
      : '${section.toLowerCase()}\u0000$sub';

  String? _parseSection(String line) {
    final m = _sectionRe.firstMatch(line);
    if (m == null) return null;
    var name = m.group(1)!;
    String? sub =
        m.group(2)?.replaceAllMapped(RegExp(r'\\(.)'), (x) => x.group(1)!);
    // Legacy `[section.sub]` syntax: git lower-cases the subsection.
    if (sub == null && name.contains('.')) {
      final dot = name.indexOf('.');
      sub = name.substring(dot + 1).toLowerCase();
      name = name.substring(0, dot);
    }
    return _sectionKey(name, sub);
  }

  /// A value as git reads it: quotes removed, escapes decoded, whitespace
  /// outside quotes trimmed at the ends (and kept as spaces inside).
  static String _parseValue(String raw) {
    final sb = StringBuffer();
    var quoted = false;
    var spaces = 0;
    for (var i = 0; i < raw.length; i++) {
      final c = raw[i];
      if (!quoted && (c == ' ' || c == '\t')) {
        spaces++;
        continue;
      }
      if (!quoted && (c == '#' || c == ';')) break;
      if (sb.isNotEmpty) sb.write(' ' * spaces);
      spaces = 0;
      if (c == '"') {
        quoted = !quoted;
      } else if (c == r'\' && i + 1 < raw.length) {
        final n = raw[++i];
        sb.write(switch (n) { 'n' => '\n', 't' => '\t', 'b' => '\b', _ => n });
      } else {
        sb.write(c);
      }
    }
    return sb.toString();
  }

  /// All values of `section.sub.key`, in file order.
  List<String> getAll(String section, String? sub, String key) {
    final want = _sectionKey(section, sub);
    final out = <String>[];
    String? current;
    for (final line in _lines) {
      final s = _parseSection(line);
      if (s != null) {
        current = s;
        continue;
      }
      if (current != want) continue;
      final m = _keyRe.firstMatch(line);
      if (m != null && m.group(1)!.toLowerCase() == key.toLowerCase()) {
        out.add(m.group(2) == null ? 'true' : _parseValue(m.group(2)!));
      }
    }
    return out;
  }

  String? get(String section, String? sub, String key) {
    final all = getAll(section, sub, key);
    return all.isEmpty ? null : all.last;
  }

  static String _quote(String v) {
    final needs = v.isEmpty || v.trim() != v || v.contains(RegExp(r'[#;"\\]'));
    final esc = v.replaceAll('\\', r'\\').replaceAll('"', r'\"');
    return needs ? '"$esc"' : esc;
  }

  /// Sets `section.sub.key` (replacing existing values) to [value].
  void set(String section, String? sub, String key, String value) {
    final want = _sectionKey(section, sub);
    String? current;
    var sectionEnd = -1;
    var replaced = false;
    for (var i = 0; i < _lines.length; i++) {
      final s = _parseSection(_lines[i]);
      if (s != null) {
        current = s;
        if (s == want) sectionEnd = i + 1;
        continue;
      }
      if (current != want) continue;
      sectionEnd = i + 1;
      final m = _keyRe.firstMatch(_lines[i]);
      if (m != null && m.group(1)!.toLowerCase() == key.toLowerCase()) {
        if (replaced) {
          _lines.removeAt(i--);
          sectionEnd--;
        } else {
          _lines[i] = '\t$key = ${_quote(value)}';
          replaced = true;
        }
      }
    }
    if (replaced) return;
    if (sectionEnd < 0) {
      _lines.add(sub == null
          ? '[$section]'
          : '[$section "${sub.replaceAll('\\', r'\\').replaceAll('"', r'\"')}"]');
      sectionEnd = _lines.length;
    }
    _lines.insert(sectionEnd, '\t$key = ${_quote(value)}');
  }

  /// Removes `[section "sub"]` and its keys (like `git config --remove-section`).
  void removeSection(String section, String? sub) {
    final want = _sectionKey(section, sub);
    var inside = false;
    _lines.removeWhere((line) {
      final s = _parseSection(line);
      if (s != null) inside = s == want;
      return inside;
    });
  }

  void save() => writeFileAtomic(path, utf8Bytes('${_lines.join('\n')}\n'));
}
