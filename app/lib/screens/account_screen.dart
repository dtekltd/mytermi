import 'package:flutter/material.dart';

import '../services/account_service.dart';
import '../services/api_client.dart';
import '../services/app_services.dart';
import '../services/sync_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/settings_tiles.dart';
import 'login_screen.dart';
import 'vault_screens.dart';

String _friendly(Object e) => e is ApiException ? e.friendly : 'Something went wrong: $e';

String syncSummary(SyncService s) {
  return switch (s.phase) {
    SyncPhase.off => 'Not signed in',
    SyncPhase.needsVault => 'Sync is off',
    SyncPhase.locked => 'Sync is locked on this device',
    SyncPhase.ready when s.syncing => 'Syncing…',
    SyncPhase.ready when s.error != null => s.error!,
    SyncPhase.ready =>
      s.lastSynced == null
          ? 'Sync is on'
          : 'Last synced ${TimeOfDay.fromDateTime(s.lastSynced!).format24()} · ${s.syncedItems} items',
  };
}

extension on TimeOfDay {
  String format24() => '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

/// Signed-in account: sync status, password, devices, sign out, delete.
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key, required this.app});
  final AppServices app;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([app.account, app.sync]),
      builder: (context, _) {
        final a = app.account.account;
        if (a == null) return LoginScreen(app: app);
        final c = context.colors;
        return Scaffold(
          appBar: AppBar(title: const Text('Account')),
          body: RefreshIndicator(
            onRefresh: () async {
              try {
                await app.account.refreshAccount();
              } catch (_) {}
              await app.sync.refresh();
            },
            child: ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 28,
                        backgroundColor: c.green,
                        child: Text(
                          (a.name.isNotEmpty ? a.name : a.email)[0].toUpperCase(),
                          style: TextStyle(color: c.onGreen, fontSize: 24, fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (a.name.isNotEmpty)
                              Text(a.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                            Text(a.email, style: TextStyle(color: a.name.isEmpty ? c.text : c.textDim, fontSize: 15)),
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(color: c.greenBg, borderRadius: BorderRadius.circular(8)),
                              child: Text(planLabel(a), style: TextStyle(color: c.green, fontSize: 12.5)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SectionLabel('Sync'),
                _SyncCard(app: app),
                const SectionLabel('Sign-in & security'),
                SettingsGroup(
                  children: [
                    SettingsTile(
                      icon: Icons.password,
                      title: a.hasPassword ? 'Change password' : 'Set a password',
                      subtitle: a.hasPassword ? null : 'Sign in with email and password',
                      trailing: Icon(Icons.chevron_right, color: c.textDim),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SetPasswordScreen(
                            app: app,
                            mode: a.hasPassword ? PasswordMode.change : PasswordMode.create,
                          ),
                        ),
                      ),
                    ),
                    SettingsTile(
                      icon: Icons.devices,
                      title: 'Devices',
                      subtitle: a.maxDevices > 0 ? '${a.planName} plan: up to ${a.maxDevices} devices' : null,
                      trailing: Icon(Icons.chevron_right, color: c.textDim),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SessionsScreen(app: app))),
                    ),
                    if (a.providers.isNotEmpty)
                      SettingsTile(
                        icon: Icons.link,
                        title: 'Linked accounts',
                        subtitle: a.providers.map((p) => p == 'google' ? 'Google' : 'Apple').join(', '),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                SettingsGroup(
                  children: [
                    SettingsTile(
                      icon: Icons.logout,
                      title: 'Sign out',
                      subtitle: 'Data on this device is kept',
                      onTap: () => _signOut(context),
                    ),
                    SettingsTile(
                      icon: Icons.delete_forever_outlined,
                      title: 'Delete account',
                      subtitle: 'Delete your account and all synced data on the server',
                      danger: true,
                      onTap: () => _delete(context),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _signOut(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('Sync will stop on this device. Hosts, keys and snippets on this device are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok != true) return;
    await app.account.signOut();
    if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _delete(BuildContext context) async {
    final email = app.account.account!.email;
    final typed = await showTextInputDialog(
      context,
      title: 'Delete account permanently?',
      confirmText: 'Delete',
      labelText: 'Type $email to confirm',
    );
    if (typed == null || !context.mounted) return;
    if (typed.trim().toLowerCase() != email) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Email doesn\'t match. Nothing was deleted.')));
      return;
    }
    try {
      await app.account.deleteAccount();
      if (!context.mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Account deleted. Data on this device is kept.')));
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendly(e))));
    }
  }
}

class _SyncCard extends StatelessWidget {
  const _SyncCard({required this.app});
  final AppServices app;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = app.sync;
    final a = app.account.account!;
    void go(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));

    final (IconData icon, Color color, String title, String body, List<Widget> actions) = switch (s.phase) {
      _ when !a.syncEnabled => (
        Icons.cloud_off,
        c.textDim,
        'Your plan doesn\'t include sync',
        'Contact your administrator to upgrade your plan.',
        <Widget>[],
      ),
      SyncPhase.needsVault => (
        Icons.cloud_upload_outlined,
        c.blue,
        'Turn on sync',
        'Set a vault password to encrypt your data before it is sent to the server. Only you can unlock it.',
        [
          FilledButton(
            onPressed: () => go(VaultSetupScreen(app: app)),
            child: const Text('Turn on sync'),
          ),
        ],
      ),
      SyncPhase.locked => (
        Icons.lock_outline,
        c.amber,
        'Unlock sync',
        'This account already has synced data. Enter your vault password to unlock it on this device.',
        [
          FilledButton(
            onPressed: () => go(VaultUnlockScreen(app: app)),
            child: const Text('Unlock'),
          ),
        ],
      ),
      SyncPhase.ready => (
        s.error != null ? Icons.sync_problem : Icons.cloud_done_outlined,
        s.error != null ? c.red : c.green,
        s.syncing ? 'Syncing…' : (s.error != null ? 'Sync error' : 'Sync is on'),
        s.error ?? syncSummary(s),
        [
          FilledButton.tonal(onPressed: s.syncing ? null : () => s.syncNow(), child: const Text('Sync now')),
          TextButton(
            onPressed: () => go(VaultPasswordScreen(app: app)),
            child: const Text('Change vault password'),
          ),
        ],
      ),
      SyncPhase.off => (Icons.cloud_off, c.textDim, 'Not signed in', '', <Widget>[]),
    };

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (s.syncing)
                SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5, color: color))
              else
                Icon(icon, color: color, size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          if (body.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(body, style: TextStyle(color: c.textDim, height: 1.4)),
          ],
          if (s.phase == SyncPhase.ready && s.pendingChanges > 0 && !s.syncing) ...[
            const SizedBox(height: 4),
            Text('${s.pendingChanges} changes waiting to sync', style: TextStyle(color: c.amber, fontSize: 13)),
          ],
          if (actions.isNotEmpty) ...[const SizedBox(height: 12), Wrap(spacing: 8, runSpacing: 8, children: actions)],
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 16, color: c.textDim),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Hosts, private keys, SSH passwords and snippets are end-to-end encrypted.',
                  style: TextStyle(color: c.textDim, fontSize: 12.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Devices signed in to this account.
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key, required this.app});
  final AppServices app;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  List<Map<String, dynamic>>? _list;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await widget.app.account.sessions();
      if (mounted) setState(() => _list = l);
    } catch (e) {
      if (mounted) setState(() => _error = _friendly(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: _list == null
          ? Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 40),
              children: [
                for (final s in _list!)
                  ItemCard(
                    icon: s['platform'] == 'android' ? Icons.phone_android : Icons.phone_iphone,
                    iconColor: s['current'] == true ? c.green : c.blue,
                    title: '${s['device_name'] ?? 'Device'}${s['current'] == true ? ' (this device)' : ''}',
                    subtitle: 'Active ${_ago(s['last_used_at'] as String)} · ${s['ip']}',
                    trailing: s['current'] == true
                        ? null
                        : IconButton(
                            tooltip: 'Sign out device',
                            icon: Icon(Icons.logout, color: c.red),
                            onPressed: () async {
                              await widget.app.account.revokeSession(s['id'] as String);
                              _load();
                            },
                          ),
                  ),
              ],
            ),
    );
  }

  static String _ago(String iso) {
    final d = DateTime.now().difference(DateTime.parse(iso));
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}

/// "Pro plan" or "Pro plan · expires 26/12/2026".
String planLabel(Account a) {
  final e = a.planExpiresAt;
  if (e == null) return '${a.planName} plan';
  return '${a.planName} plan · expires ${e.day.toString().padLeft(2, '0')}/${e.month.toString().padLeft(2, '0')}/${e.year}';
}
