import 'command_store.dart';
import 'host_store.dart';
import 'session_manager.dart';
import 'settings_store.dart';

/// The app's long-lived stores, passed down to screens.
class AppServices {
  AppServices({required this.hosts, required this.commands, required this.settings})
      : sessions = SessionManager(hosts: hosts, commands: commands, settings: settings);
  final HostStore hosts;
  final CommandStore commands;
  final SettingsStore settings;
  final SessionManager sessions;
}
