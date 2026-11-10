import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/snippet.dart';

class HistoryEntry {
  HistoryEntry(this.cmd, this.count, this.lastUsed);
  final String cmd;
  int count;
  int lastUsed; // ms since epoch

  /// Frequency decayed by age (half-life two weeks).
  double score(int now) {
    final ageDays = (now - lastUsed) / Duration.millisecondsPerDay;
    return count * pow(0.5, ageDays / 14).toDouble();
  }

  Map<String, dynamic> toJson() => {'c': cmd, 'n': count, 't': lastUsed};
  factory HistoryEntry.fromJson(Map<String, dynamic> j) =>
      HistoryEntry(j['c'] as String, j['n'] as int, j['t'] as int);
}

/// One item in the suggestion bar: a history command or a snippet.
class Suggestion {
  const Suggestion.history(this.text) : snippet = null;
  Suggestion.snippet(Snippet this.snippet) : text = snippet.command;
  final String text;
  final Snippet? snippet;
  bool get isSnippet => snippet != null;
}

/// Per-host command history + global snippets.
class CommandStore extends ChangeNotifier {
  CommandStore._(this._prefs);

  static const maxHistory = 500;
  static const _snippetsKey = 'snippets_v1';

  final SharedPreferences _prefs;
  final Map<String, List<HistoryEntry>> _history = {};
  final List<Snippet> _snippets = [];

  static Future<CommandStore> load() async {
    final s = CommandStore._(await SharedPreferences.getInstance());
    final raw = s._prefs.getString(_snippetsKey);
    if (raw != null) {
      s._snippets.addAll((jsonDecode(raw) as List).cast<Map<String, dynamic>>().map(Snippet.fromJson));
    }
    return s;
  }

  // ------------------------------------------------------------ snippets

  List<Snippet> get snippets => List.unmodifiable(_snippets);

  Future<void> saveSnippet(Snippet s) async {
    final i = _snippets.indexWhere((x) => x.id == s.id);
    i >= 0 ? _snippets[i] = s : _snippets.add(s);
    await _persistSnippets();
  }

  Future<void> deleteSnippet(Snippet s) async {
    _snippets.removeWhere((x) => x.id == s.id);
    await _persistSnippets();
  }

  /// [to] is the index after removal (ReorderableListView.onReorderItem).
  Future<void> reorderSnippet(int from, int to) async {
    _snippets.insert(to, _snippets.removeAt(from));
    await _persistSnippets();
  }

  Future<void> _persistSnippets() async {
    await _prefs.setString(_snippetsKey, jsonEncode(_snippets.map((s) => s.toJson()).toList()));
    notifyListeners();
  }

  // ------------------------------------------------------------- history

  String _histKey(String hostId) => 'hist_$hostId';

  List<HistoryEntry> _entries(String hostId) => _history.putIfAbsent(hostId, () {
        final raw = _prefs.getString(_histKey(hostId));
        if (raw == null) return [];
        return (jsonDecode(raw) as List).cast<Map<String, dynamic>>().map(HistoryEntry.fromJson).toList();
      });

  int historyCount(String hostId) => _entries(hostId).length;

  Future<void> addHistory(String hostId, String cmd, {int? at}) async {
    _add(_entries(hostId), cmd.trim(), at ?? DateTime.now().millisecondsSinceEpoch);
    await _persistHistory(hostId);
  }

  void _add(List<HistoryEntry> list, String cmd, int at) {
    if (cmd.isEmpty || cmd.length > 1000) return;
    final i = list.indexWhere((e) => e.cmd == cmd);
    if (i >= 0) {
      list[i].count++;
      list[i].lastUsed = max(list[i].lastUsed, at);
    } else {
      list.add(HistoryEntry(cmd, 1, at));
    }
  }

  Future<void> removeHistory(String hostId, String cmd) async {
    _entries(hostId).removeWhere((e) => e.cmd == cmd);
    await _persistHistory(hostId);
  }

  Future<void> clearHistory(String hostId) async {
    _history.remove(hostId);
    await _prefs.remove(_histKey(hostId));
    notifyListeners();
  }

  Future<void> clearAllHistory() async {
    _history.clear();
    for (final k in _prefs.getKeys().where((k) => k.startsWith('hist_')).toList()) {
      await _prefs.remove(k);
    }
    notifyListeners();
  }

  /// Imports a shell history file (bash, zsh or fish format). Returns how many
  /// distinct commands it contained.
  Future<int> importHistory(String hostId, String raw) async {
    final cmds = parseShellHistory(raw);
    final list = _entries(hostId);
    // Older than anything typed in-app, but keep the file's relative order.
    final base = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch;
    for (var i = 0; i < cmds.length; i++) {
      _add(list, cmds[i], base + i);
    }
    await _persistHistory(hostId);
    return cmds.toSet().length;
  }

  Future<void> _persistHistory(String hostId) async {
    final list = _entries(hostId);
    if (list.length > maxHistory) {
      final now = DateTime.now().millisecondsSinceEpoch;
      list.sort((a, b) => b.score(now).compareTo(a.score(now)));
      list.removeRange(maxHistory, list.length);
    }
    await _prefs.setString(_histKey(hostId), jsonEncode(list.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  // ---------------------------------------------------------- suggestions

  /// Suggestions for what the user has typed so far.
  /// Empty input: snippets, then most-used commands.
  /// Otherwise: history starting with the input, matching snippets, then
  /// history containing the input anywhere.
  List<Suggestion> suggest(String hostId, String input, {int limit = 20}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final ranked = [..._entries(hostId)]..sort((a, b) => b.score(now).compareTo(a.score(now)));
    final out = <Suggestion>[];
    final seen = <String>{};

    void addHist(HistoryEntry e) {
      if (seen.add(e.cmd)) out.add(Suggestion.history(e.cmd));
    }

    if (input.trim().isEmpty) {
      out.addAll(_snippets.map(Suggestion.snippet));
      ranked.take(limit).forEach(addHist);
      return out.take(limit).toList();
    }

    final q = input.toLowerCase();
    seen.add(input); // never suggest exactly what's already typed
    for (final e in ranked) {
      if (e.cmd.startsWith(input)) addHist(e);
    }
    for (final s in _snippets) {
      if (s.name.toLowerCase().contains(q) || s.command.toLowerCase().contains(q)) {
        out.add(Suggestion.snippet(s));
      }
    }
    for (final e in ranked) {
      if (e.cmd.toLowerCase().contains(q)) addHist(e);
    }
    return out.take(limit).toList();
  }
}

/// Parses bash / zsh (extended) / fish history into commands, oldest first.
List<String> parseShellHistory(String raw) {
  final zshExt = RegExp(r'^: \d+:\d+;');
  final bashTs = RegExp(r'^#\d{9,}$');
  final out = <String>[];
  for (var line in const LineSplitter().convert(raw)) {
    if (bashTs.hasMatch(line)) continue;
    if (line.startsWith('- cmd: ')) {
      line = line.substring(7); // fish
    } else if (line.startsWith('  when: ') || line.startsWith('  paths:') || line.startsWith('    - ')) {
      continue; // fish metadata
    }
    line = line.replaceFirst(zshExt, '').trim();
    if (line.isEmpty || line.endsWith('\\')) continue; // skip multi-line fragments
    out.add(line);
  }
  return out;
}
