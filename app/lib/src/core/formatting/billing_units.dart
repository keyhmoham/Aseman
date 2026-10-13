/// Money and credit conversions used at API/UI boundaries.
///
/// The backend stores one US dollar as 1,000,000 ledger units. People see
/// credits, where one credit is one cent, so one credit is 10,000 units.
const int ledgerUnitsPerUsd = 1000000;
const int ledgerUnitsPerCredit = 10000;

double ledgerToUsd(num units) => units / ledgerUnitsPerUsd;
double ledgerToCredits(num units) => units / ledgerUnitsPerCredit;
int usdToLedger(num usd) => (usd * ledgerUnitsPerUsd).round();
int creditsToLedger(num credits) => (credits * ledgerUnitsPerCredit).round();

String compactDecimal(num value, {int decimals = 4}) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value
      .toStringAsFixed(decimals)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

String formatLedgerCredits(num units, {bool exact = false}) {
  final value = ledgerToCredits(units.abs());
  final sign = units < 0 ? '−' : '';
  if (!exact && value > 0 && value < 1) return '${sign}<1 credit';
  final amount = exact ? compactDecimal(value) : value.floor().toString();
  return '$sign$amount credit${value == 1 ? '' : 's'}';
}

String formatLedgerUsd(num units) {
  final value = ledgerToUsd(units);
  final decimals = value.abs() > 0 && value.abs() < .01 ? 4 : 2;
  return '\$${value.toStringAsFixed(decimals)}';
}

String formatLedgerUsdPerMillion(num units) {
  final value = ledgerToUsd(units);
  if (value == 0) return '\$0';
  final text = value >= 1
      ? value.toStringAsFixed(2)
      : value
          .toStringAsFixed(6)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
  return '\$$text';
}

String ledgerCreditsField(num units) =>
    units == 0 ? '' : compactDecimal(ledgerToCredits(units));

String ledgerUsdField(num units) =>
    units == 0 ? '' : compactDecimal(ledgerToUsd(units), decimals: 6);

int? parseCreditsToLedger(String raw) {
  final value = double.tryParse(raw.trim().replaceAll(',', ''));
  return value == null || value < 0 ? null : creditsToLedger(value);
}

int? parseUsdToLedger(String raw) {
  final value = double.tryParse(
      raw.trim().replaceFirst(RegExp(r'^\$'), '').replaceAll(',', ''));
  return value == null || value < 0 ? null : usdToLedger(value);
}
