DateTime? asDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is String) return DateTime.parse(value).toUtc();
  return null;
}

DateTime requireDateTime(Object? value) => asDateTime(value)!;

double? asDouble(Object? value) {
  if (value == null) return null;
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int asInt(Object? value, [int fallback = 0]) {
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is BigInt) return value.toInt();
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

bool asBool(Object? value) {
  if (value == null) return false;
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value == 'true' || value == '1';
  return false;
}

String? asString(Object? value) => value?.toString();
