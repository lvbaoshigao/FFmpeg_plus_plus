/// A normalized search over setting names, descriptions, and common aliases.
final class SettingsSearch {
  SettingsSearch(String query) : _terms = _parseTerms(query);

  final List<_SearchTerm> _terms;
  final Map<String, _SearchField> _fields = {};

  /// Whether the query contains any searchable text.
  bool get isEmpty => _terms.isEmpty;

  /// Ranks a setting whose text covers every term, or returns zero.
  int score({
    required String title,
    required String alternateTitle,
    required Iterable<String> keywords,
    required String section,
    required String alternateSection,
  }) {
    var total = 0;
    for (final term in _terms) {
      var best = 0;
      void consider(String text, int bonus, {bool fuzzy = true}) {
        final match = _field(text).match(term, fuzzy: fuzzy);
        if (match != null && match.score + bonus > best) {
          best = match.score + bonus;
        }
      }

      consider(title, 12);
      consider(alternateTitle, 8);
      for (final keyword in keywords) {
        consider(keyword, 0);
      }
      // A category name is an umbrella match for its settings. Typos in a
      // category name should not introduce all of its unrelated settings.
      consider(section, -5, fuzzy: false);
      consider(alternateSection, -6, fuzzy: false);
      if (best == 0) {
        return 0;
      }
      total += best;
    }
    return total;
  }

  /// Returns ordered, nonoverlapping ranges in the original label.
  List<({int start, int end})> highlights(String text) {
    if (isEmpty) {
      return const [];
    }
    final field = _field(text);
    final ranges = <({int start, int end})>[];
    for (final term in _terms) {
      final match = field.match(term);
      if (match == null) {
        continue;
      }
      var at = match.offset;
      do {
        ranges.add((
          start: field.starts[at],
          end: field.ends[at + match.text.length - 1],
        ));
        at = field.value.indexOf(match.text, at + match.text.length);
      } while (at >= 0);
    }
    ranges.sort((a, b) => a.start.compareTo(b.start));
    final merged = <({int start, int end})>[];
    for (final range in ranges) {
      if (merged.isNotEmpty && range.start <= merged.last.end) {
        final previous = merged.removeLast();
        merged.add((
          start: previous.start,
          end: range.end > previous.end ? range.end : previous.end,
        ));
      } else {
        merged.add(range);
      }
    }
    return merged;
  }

  /// Finds displayable phrases for hits that aren't visible in the headings.
  List<String> evidence({
    required String title,
    required String section,
    required Iterable<String> candidates,
  }) {
    final labels = <String>{};
    for (final term in _terms) {
      if (_field(title).match(term) != null ||
          _field(section).match(term, fuzzy: false) != null) {
        continue;
      }
      var best = 0;
      String? label;
      for (final candidate in candidates) {
        final match = _field(candidate).match(term);
        if (match != null && match.score > best) {
          best = match.score;
          label = candidate;
        }
      }
      if (label != null) {
        labels.add(label);
      }
      if (labels.length == 3) {
        break;
      }
    }
    return labels.toList(growable: false);
  }

  _SearchField _field(String text) =>
      _fields.putIfAbsent(text, () => _SearchField(text));
}

// Every group contains labels people use for the same setting. Alias and
// fuzzy hits receive lower scores so typing the visible text wins.
const _aliasGroups = [
  ['壁纸', '背景', '背景图', 'wallpaper', 'background'],
  ['字号', '字体大小', '文字大小', 'font size', 'text size'],
  ['深色', '暗色', '夜间模式', 'dark', 'dark mode', 'night mode'],
  ['主题色', '强调色', '配色', 'accent', 'theme color', 'accent color'],
  ['快捷键', '热键', '键位', 'shortcuts', 'hotkey', 'keybinding'],
  ['自动保存', '草稿', 'autosave', 'auto save', 'draft'],
  ['液态玻璃', '玻璃', 'liquid glass', 'glass'],
  ['模糊', '毛玻璃', '磨砂', 'blur', 'frosted'],
  ['预加载', '预热', 'preload', 'prewarm'],
  ['缓存', '清缓存', 'cache', 'cleanup', 'purge'],
];

final _aliases = <String, Set<String>>{
  for (final group in _aliasGroups)
    for (final label in group) _normalize(label): group.map(_normalize).toSet(),
};
final _separator = RegExp(r'[\s_\-./:()（）·,，、;；。]+');
final _termSeparator = RegExp(r'[\s,，、;；]+');

String _normalize(String text) => text.toLowerCase().replaceAll(_separator, '');

typedef _SearchTerm = ({String text, List<String> aliases});

List<_SearchTerm> _parseTerms(String query) {
  final normalized = _normalize(query);
  // Preserve known compounds such as "font size" and "liquid glass".
  final tokens = _aliases.containsKey(normalized)
      ? [normalized]
      : query.split(_termSeparator).map(_normalize);
  return [
    for (final token in tokens.where((token) => token.isNotEmpty).toSet())
      (
        text: token,
        aliases: [
          for (final alias in _aliases[token] ?? const {})
            if (alias != token) alias,
        ],
      ),
  ];
}

typedef _Match = ({int score, String text, int offset});

final class _SearchField {
  _SearchField(String text) {
    final buffer = StringBuffer();
    var offset = 0;
    for (final rune in text.runes) {
      final character = String.fromCharCode(rune);
      final folded = _normalize(character);
      final end = offset + character.length;
      for (var i = 0; i < folded.length; i++) {
        starts.add(offset);
        ends.add(end);
      }
      buffer.write(folded);
      offset = end;
    }
    value = buffer.toString();

    offset = 0;
    for (final word in text.split(_separator)) {
      final folded = _normalize(word);
      if (folded.isNotEmpty) {
        _words.add((text: folded, offset: offset));
        offset += folded.length;
      }
    }
  }

  late final String value;
  final starts = <int>[];
  final ends = <int>[];
  final _words = <({String text, int offset})>[];

  _Match? match(_SearchTerm term, {bool fuzzy = true}) {
    final at = value.indexOf(term.text);
    if (at >= 0) {
      final score = value == term.text ? 90 : (at == 0 ? 80 : 70);
      return (score: score, text: term.text, offset: at);
    }
    _Match? bestAlias;
    for (final alias in term.aliases) {
      final offset = value.indexOf(alias);
      if (offset >= 0) {
        final score = value == alias ? 48 : (offset == 0 ? 42 : 36);
        if (bestAlias == null || score > bestAlias.score) {
          bestAlias = (score: score, text: alias, offset: offset);
        }
      }
    }
    if (bestAlias != null || !fuzzy || term.text.runes.length < 4) {
      return bestAlias;
    }
    if (_oneEditApart(term.text, value)) {
      return (score: 20, text: value, offset: 0);
    }
    for (final word in _words) {
      if (_oneEditApart(term.text, word.text)) {
        return (score: 18, text: word.text, offset: word.offset);
      }
    }
    return null;
  }
}

// Accept a missing, extra, replaced or adjacent-swapped character.
bool _oneEditApart(String first, String second) {
  if ((first.length - second.length).abs() > 1) {
    return false;
  }
  final shorter = first.length <= second.length ? first : second;
  final longer = first.length <= second.length ? second : first;
  var start = 0;
  while (start < shorter.length && shorter[start] == longer[start]) {
    start++;
  }
  if (start == shorter.length) {
    return longer.length > shorter.length;
  }
  final rest = start + 1;
  if (shorter.length != longer.length) {
    return shorter.substring(start) == longer.substring(rest);
  }
  if (shorter.substring(rest) == longer.substring(rest)) {
    return true;
  }
  final afterPair = rest + 1;
  return rest < shorter.length &&
      shorter[start] == longer[rest] &&
      shorter[rest] == longer[start] &&
      shorter.substring(afterPair) == longer.substring(afterPair);
}
