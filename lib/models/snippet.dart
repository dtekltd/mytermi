class Snippet {
  Snippet({
    required this.id,
    required this.name,
    required this.command,
    this.autoRun = true,
  });

  final String id;
  String name;
  String command;

  /// Press Enter automatically after inserting the command.
  bool autoRun;

  String get displayName => name.trim().isEmpty ? command.split('\n').first : name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'command': command, 'autoRun': autoRun};

  factory Snippet.fromJson(Map<String, dynamic> j) => Snippet(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        command: j['command'] as String,
        autoRun: (j['autoRun'] ?? true) as bool,
      );
}
