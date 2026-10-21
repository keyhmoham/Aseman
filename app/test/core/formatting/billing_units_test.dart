import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/core/formatting/billing_units.dart';

void main() {
  test('ledger amounts cross the UI boundary as dollars and credits', () {
    expect(formatLedgerUsd(1200000), r'$1.20');
    expect(formatLedgerCredits(1200000), '120 credits');
    expect(formatLedgerCredits(500, exact: true), '0.05 credits');
    expect(parseCreditsToLedger('12.5'), 125000);
    expect(parseUsdToLedger('2.50'), 2500000);
    expect(ledgerUsdField(2500000), '2.5');
  });
}
