/// Small display formatters.
///
/// Kept separate from the widgets so they can be unit-tested without a widget
/// tree, and so the "no snapshot" case has exactly one implementation.
library;

/// Formats a byte count into a short human-readable size.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  // One decimal above KB: "1.5 MB" is useful, "1.0 B" is not.
  final digits = unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Formats a millisecond timestamp as a local date-time.
String formatDateTime(int millis) {
  if (millis <= 0) return '—';
  final dt = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
  return '${dt.year}-${_two(dt.month)}-${_two(dt.day)} ${_two(dt.hour)}:${_two(dt.minute)}';
}

String formatDate(int millis) {
  if (millis <= 0) return '—';
  final dt = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
  return '${dt.year}-${_two(dt.month)}-${_two(dt.day)}';
}

/// Formats a millisecond timestamp as an elapsed-time phrase.
///
/// Used for "indexed 5 minutes ago" and, more importantly, for how stale the
/// metadata snapshot is — the one number a user needs in order to interpret
/// everything else on the screen.
String formatRelative(int millis, {int? nowMs}) {
  if (millis <= 0) return '未知';
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final delta = now - millis;

  if (delta < 0) {
    // Clock skew between client and server; not worth alarming about.
    return '刚刚';
  }
  final seconds = delta ~/ 1000;
  if (seconds < 60) return '$seconds 秒前';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes 分钟前';
  final hours = minutes ~/ 60;
  if (hours < 24) return '$hours 小时前';
  final days = hours ~/ 24;
  if (days < 30) return '$days 天前';
  final months = days ~/ 30;
  if (months < 12) return '$months 个月前';
  return '${days ~/ 365} 年前';
}

/// Formats the language code the server derives into a display name.
///
/// The server sends ISO 639-1 codes with no display name, so the mapping lives
/// here where it can be translated.
String languageLabel(String code) => switch (code.toUpperCase()) {
      'EN' => '英语',
      'ZH' => '中文',
      'ES' => '西班牙语',
      'KO' => '韩语',
      'RU' => '俄语',
      'FR' => '法语',
      'PT' => '葡萄牙语',
      'TH' => '泰语',
      'DE' => '德语',
      'IT' => '意大利语',
      'VI' => '越南语',
      'PL' => '波兰语',
      'HU' => '匈牙利语',
      'NL' => '荷兰语',
      'JA' => '日语',
      _ => code,
    };

/// A display name for the category integer.
///
/// The backend deliberately treats this as an opaque integer, because the
/// `EhUtils` enum it comes from lives in an AAR dependency and could not be
/// verified against source. So this mapping is also a best-effort guess, and
/// the number is shown alongside it so a wrong guess is visible rather than
/// authoritative.
String categoryLabel(int category) => switch (category) {
      1 => '同人志',
      2 => '漫画',
      3 => '画师 CG',
      4 => '游戏 CG',
      5 => '欧美',
      6 => '非 H',
      7 => '图集',
      8 => 'Cosplay',
      9 => '亚洲',
      10 => '其他',
      _ => '未分类',
    };

/// Number of stars to render for a 0-5 rating, rounded to the nearest half.
int ratingHalfStars(double rating) {
  if (rating <= 0) return 0;
  return (rating * 2).round().clamp(0, 10);
}

String _two(int value) => value < 10 ? '0$value' : '$value';
