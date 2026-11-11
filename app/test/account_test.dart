import 'package:flutter_test/flutter_test.dart';
import 'package:mytermi/screens/account_screen.dart';
import 'package:mytermi/services/account_service.dart';

void main() {
  Account account(Map<String, dynamic> plan) => Account.fromJson({'id': 'u1', 'email': 'a@b.c', 'plan': plan});

  test('plan label shows the end date when the plan has one', () {
    final a = account({'id': 'pro', 'name': 'Pro', 'expires_at': '2026-12-26T16:59:59Z'});
    expect(a.planExpiresAt, DateTime.utc(2026, 12, 26, 16, 59, 59).toLocal());
    final d = a.planExpiresAt!;
    expect(planLabel(a), 'Pro plan · expires ${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}');
  });

  test('plan label without an end date (or an older server)', () {
    expect(planLabel(account({'id': 'pro', 'name': 'Pro', 'expires_at': null})), 'Pro plan');
    expect(planLabel(account({'id': 'free', 'name': 'Free'})), 'Free plan');
  });
}
