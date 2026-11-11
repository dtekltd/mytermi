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

String _friendly(Object e) => e is ApiException ? e.friendly : 'Có lỗi xảy ra: $e';

String syncSummary(SyncService s) {
  return switch (s.phase) {
    SyncPhase.off => 'Chưa đăng nhập',
    SyncPhase.needsVault => 'Chưa bật đồng bộ',
    SyncPhase.locked => 'Đồng bộ đang khoá trên máy này',
    SyncPhase.ready when s.syncing => 'Đang đồng bộ…',
    SyncPhase.ready when s.error != null => s.error!,
    SyncPhase.ready =>
      s.lastSynced == null
          ? 'Đã bật đồng bộ'
          : 'Đã đồng bộ lúc ${TimeOfDay.fromDateTime(s.lastSynced!).format24()} · ${s.syncedItems} mục',
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
          appBar: AppBar(title: const Text('Tài khoản')),
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
                const SectionLabel('Đồng bộ'),
                _SyncCard(app: app),
                const SectionLabel('Đăng nhập & bảo mật'),
                SettingsGroup(
                  children: [
                    SettingsTile(
                      icon: Icons.password,
                      title: a.hasPassword ? 'Đổi mật khẩu đăng nhập' : 'Đặt mật khẩu đăng nhập',
                      subtitle: a.hasPassword ? null : 'Để đăng nhập bằng email + mật khẩu',
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
                      title: 'Thiết bị đã đăng nhập',
                      subtitle: a.maxDevices > 0 ? 'Gói ${a.planName}: tối đa ${a.maxDevices} thiết bị' : null,
                      trailing: Icon(Icons.chevron_right, color: c.textDim),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SessionsScreen(app: app))),
                    ),
                    if (a.providers.isNotEmpty)
                      SettingsTile(
                        icon: Icons.link,
                        title: 'Tài khoản liên kết',
                        subtitle: a.providers.map((p) => p == 'google' ? 'Google' : 'Apple').join(', '),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                SettingsGroup(
                  children: [
                    SettingsTile(
                      icon: Icons.logout,
                      title: 'Đăng xuất',
                      subtitle: 'Dữ liệu trên máy này được giữ nguyên',
                      onTap: () => _signOut(context),
                    ),
                    SettingsTile(
                      icon: Icons.delete_forever_outlined,
                      title: 'Xoá tài khoản',
                      subtitle: 'Xoá tài khoản và toàn bộ dữ liệu đã đồng bộ trên máy chủ',
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
        title: const Text('Đăng xuất?'),
        content: const Text('Đồng bộ sẽ dừng trên máy này. Host, key và snippet trên máy vẫn được giữ lại.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Đăng xuất')),
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
      title: 'Xoá tài khoản vĩnh viễn?',
      confirmText: 'Xoá',
      labelText: 'Nhập $email để xác nhận',
    );
    if (typed == null || !context.mounted) return;
    if (typed.trim().toLowerCase() != email) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Email không khớp, chưa xoá gì.')));
      return;
    }
    try {
      await app.account.deleteAccount();
      if (!context.mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Đã xoá tài khoản. Dữ liệu trên máy này vẫn còn.')));
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
        'Gói hiện tại không có đồng bộ',
        'Liên hệ quản trị viên để nâng cấp gói.',
        <Widget>[],
      ),
      SyncPhase.needsVault => (
        Icons.cloud_upload_outlined,
        c.blue,
        'Bật đồng bộ',
        'Đặt mật khẩu vault để mã hoá dữ liệu trước khi gửi lên máy chủ. Chỉ bạn mở khoá được.',
        [
          FilledButton(
            onPressed: () => go(VaultSetupScreen(app: app)),
            child: const Text('Bật đồng bộ'),
          ),
        ],
      ),
      SyncPhase.locked => (
        Icons.lock_outline,
        c.amber,
        'Mở khoá đồng bộ',
        'Tài khoản đã có dữ liệu đồng bộ. Nhập mật khẩu vault để mở khoá trên máy này.',
        [
          FilledButton(
            onPressed: () => go(VaultUnlockScreen(app: app)),
            child: const Text('Mở khoá'),
          ),
        ],
      ),
      SyncPhase.ready => (
        s.error != null ? Icons.sync_problem : Icons.cloud_done_outlined,
        s.error != null ? c.red : c.green,
        s.syncing ? 'Đang đồng bộ…' : (s.error != null ? 'Lỗi đồng bộ' : 'Đồng bộ đang bật'),
        s.error ?? syncSummary(s),
        [
          FilledButton.tonal(onPressed: s.syncing ? null : () => s.syncNow(), child: const Text('Đồng bộ ngay')),
          TextButton(
            onPressed: () => go(VaultPasswordScreen(app: app)),
            child: const Text('Đổi mật khẩu vault'),
          ),
        ],
      ),
      SyncPhase.off => (Icons.cloud_off, c.textDim, 'Chưa đăng nhập', '', <Widget>[]),
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
            Text('${s.pendingChanges} thay đổi chờ gửi', style: TextStyle(color: c.amber, fontSize: 13)),
          ],
          if (actions.isNotEmpty) ...[const SizedBox(height: 12), Wrap(spacing: 8, runSpacing: 8, children: actions)],
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 16, color: c.textDim),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Host, private key, password SSH và snippet được mã hoá đầu-cuối.',
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
      appBar: AppBar(title: const Text('Thiết bị đã đăng nhập')),
      body: _list == null
          ? Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 40),
              children: [
                for (final s in _list!)
                  ItemCard(
                    icon: s['platform'] == 'android' ? Icons.phone_android : Icons.phone_iphone,
                    iconColor: s['current'] == true ? c.green : c.blue,
                    title: '${s['device_name'] ?? 'Thiết bị'}${s['current'] == true ? ' (máy này)' : ''}',
                    subtitle: 'Hoạt động ${_ago(s['last_used_at'] as String)} · ${s['ip']}',
                    trailing: s['current'] == true
                        ? null
                        : IconButton(
                            tooltip: 'Đăng xuất thiết bị',
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
    if (d.inMinutes < 1) return 'vừa xong';
    if (d.inHours < 1) return '${d.inMinutes} phút trước';
    if (d.inDays < 1) return '${d.inHours} giờ trước';
    return '${d.inDays} ngày trước';
  }
}

/// "Gói Pro" or "Gói Pro · đến 26/12/2026".
String planLabel(Account a) {
  final e = a.planExpiresAt;
  if (e == null) return 'Gói ${a.planName}';
  return 'Gói ${a.planName} · đến ${e.day.toString().padLeft(2, '0')}/${e.month.toString().padLeft(2, '0')}/${e.year}';
}
