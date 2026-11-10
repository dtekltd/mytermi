import 'package:shared_preferences/shared_preferences.dart';

import 'account_service.dart';
import 'command_store.dart';
import 'host_store.dart';
import 'session_manager.dart';
import 'settings_store.dart';
import 'sync_service.dart';

/// The app's long-lived stores, passed down to screens.
class AppServices {
  AppServices({
    required this.hosts,
    required this.commands,
    required this.settings,
    required this.account,
    required this.sync,
  }) : sessions = SessionManager(hosts: hosts, commands: commands, settings: settings);

  final HostStore hosts;
  final CommandStore commands;
  final SettingsStore settings;
  final AccountService account;
  final SyncService sync;
  final SessionManager sessions;

  /// Loads every store; [startSync] = false in tests that don't need it.
  static Future<AppServices> load({bool startSync = true}) async {
    final hosts = await HostStore.load();
    final commands = await CommandStore.load();
    final account = await AccountService.load();
    final sync = SyncService(
      account: account,
      hosts: hosts,
      commands: commands,
      prefs: await SharedPreferences.getInstance(),
    );
    if (startSync) await sync.init();
    return AppServices(
      hosts: hosts,
      commands: commands,
      settings: await SettingsStore.load(),
      account: account,
      sync: sync,
    );
  }
}
