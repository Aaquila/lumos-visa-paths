import 'dart:convert';

import 'notifications/scheduled_reminder.dart';
import 'notifications/ics_download_stub.dart'
    if (dart.library.js_interop) 'notifications/ics_download_web.dart';

/// RFC 5545 iCalendar export.
///
/// ## Why this file matters more than the notification code
/// A browser cannot notify anybody with the tab closed unless there is a push
/// server behind it, and there is no push server here. A calendar entry has no
/// such limitation: once a deadline is in Google Calendar or Apple Calendar, the
/// user's phone will wake them for it whether or not they ever open Lumos
/// again. This is the reliable channel. It is worth being exactly correct.
///
/// ## Conformance
///  * CRLF line endings everywhere, including the final line (§3.1).
///  * Content lines folded at 75 **octets**, continuations prefixed with one
///    space, never splitting a UTF-8 sequence (§3.1).
///  * `DTSTAMP`, `UID`, `DTSTART` on every VEVENT (§3.6.1).
///  * All-day events use `VALUE=DATE` with a non-inclusive `DTEND` on the
///    following day (§3.6.1); timed events use UTC `DTSTART`/`DTEND`.
///  * TEXT values escape `\`, `;`, `,` and newlines (§3.3.11).
///  * One `VALARM` with a `DISPLAY` action and a relative `TRIGGER` per event.
class IcsExport {
  const IcsExport._();

  static const crlf = '\r\n';
  static const productId = '-//Lumos//Immigration Deadlines//EN';

  /// The domain half of generated UIDs. Not resolved by anything; RFC 5545 only
  /// requires global uniqueness, and the id half already carries that.
  static const uidDomain = 'lumos.app';

  /// Default duration for a timed event when we only know a start.
  static const defaultDuration = Duration(hours: 1);

  /// Builds a complete VCALENDAR from [reminders].
  ///
  /// Reminders sharing a [ScheduledReminder.group] describe the same underlying
  /// date at different lead times, so they collapse into **one** VEVENT with
  /// one VALARM per lead time — putting the same deadline into a calendar three
  /// times would be its own kind of harm.
  ///
  /// [now] is the DTSTAMP for every event; injectable so tests can pin it.
  static String build(
    List<ScheduledReminder> reminders, {
    DateTime? now,
    String calendarName = 'Lumos immigration deadlines',
  }) {
    final stamp = (now ?? DateTime.now()).toUtc();
    final lines = <String>[
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:${_escape(productId)}',
      'CALSCALE:GREGORIAN',
      'METHOD:PUBLISH',
      // X- properties are how Google and Apple pick up a calendar's display
      // name on import. Not required by the RFC; harmless where unsupported.
      'X-WR-CALNAME:${_escape(calendarName)}',
      'X-WR-TIMEZONE:UTC',
    ];

    for (final group in _groupByEvent(reminders)) {
      lines.addAll(_event(group, stamp));
    }

    lines.add('END:VCALENDAR');

    return '${lines.map(foldLine).join(crlf)}$crlf';
  }

  /// One VEVENT per underlying date, alarms for each lead time on it.
  static List<String> _event(List<ScheduledReminder> group, DateTime stamp) {
    final head = group.first;
    final lines = <String>[
      'BEGIN:VEVENT',
      'UID:${_uid(head)}',
      'DTSTAMP:${formatUtc(stamp)}',
      ..._dateLines(head),
      'SUMMARY:${_escape(head.title)}',
      if (head.body.isNotEmpty) 'DESCRIPTION:${_escape(_description(head))}',
      // Deadlines are facts, not proposals: nothing here is tentative, and
      // nobody should be shown as busy for a filing date.
      'STATUS:CONFIRMED',
      'TRANSP:TRANSPARENT',
      'CATEGORIES:${_escape(head.type.label)}',
      if (head.deepLink != null && head.deepLink!.isNotEmpty)
        'URL:${_escape(head.deepLink!)}',
    ];

    // One alarm per distinct lead time, longest first, de-duplicated — two
    // reminders that round to the same trigger would ring twice.
    final triggers = <String>{};
    for (final r in group) {
      final trigger = formatTrigger(r.eventAt.difference(r.fireAt));
      if (!triggers.add(trigger)) continue;
      lines.addAll([
        'BEGIN:VALARM',
        'ACTION:DISPLAY',
        'TRIGGER:$trigger',
        'DESCRIPTION:${_escape(r.body.isEmpty ? r.title : r.body)}',
        'END:VALARM',
      ]);
    }

    lines.add('END:VEVENT');
    return lines;
  }

  /// DTSTART/DTEND, in the two forms RFC 5545 allows.
  ///
  /// All-day events must be `VALUE=DATE` with a DTEND on the *following* day:
  /// DTEND is non-inclusive, so a one-day event ending on its own date would
  /// import as a zero-length event and vanish from some clients.
  static List<String> _dateLines(ScheduledReminder r) {
    if (r.allDay) {
      final start = r.eventAt;
      final end = DateTime(
        start.year,
        start.month,
        start.day,
      ).add(const Duration(days: 1));
      return [
        'DTSTART;VALUE=DATE:${formatDate(start)}',
        'DTEND;VALUE=DATE:${formatDate(end)}',
      ];
    }
    final start = r.eventAt.toUtc();
    return [
      'DTSTART:${formatUtc(start)}',
      'DTEND:${formatUtc(start.add(defaultDuration))}',
    ];
  }

  static String _description(ScheduledReminder r) {
    final link = r.deepLink;
    final tail = link == null || link.isEmpty ? '' : '\n\nOpen in Lumos: $link';
    return '${r.body}$tail\n\n'
        'Lumos supports, and does not replace, a licensed immigration attorney.';
  }

  /// Groups reminders that describe the same underlying date, preserving the
  /// order each group was first seen so the output is deterministic.
  static List<List<ScheduledReminder>> _groupByEvent(
    List<ScheduledReminder> reminders,
  ) {
    final order = <String>[];
    final byKey = <String, List<ScheduledReminder>>{};
    for (final r in reminders) {
      final key = '${r.group}|${formatDate(r.eventAt)}';
      if (!byKey.containsKey(key)) {
        byKey[key] = <ScheduledReminder>[];
        order.add(key);
      }
      byKey[key]!.add(r);
    }
    return [
      for (final k in order)
        (byKey[k]!..sort((a, b) => b.leadTime.compareTo(a.leadTime))),
    ];
  }

  /// `lumos-<id>@lumos.app`, with anything UID-unsafe stripped.
  static String _uid(ScheduledReminder r) {
    final safe = r.group.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    final base = safe.isEmpty ? 'reminder' : safe;
    return 'lumos-$base-${formatDate(r.eventAt)}@$uidDomain';
  }

  // ── Value formatting ──────────────────────────────────────────────────────

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// `YYYYMMDD` — the DATE form, read in whatever zone [t] is already in.
  static String formatDate(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}${_two(t.month)}${_two(t.day)}';

  /// `YYYYMMDDTHHMMSSZ` — the UTC DATE-TIME form.
  static String formatUtc(DateTime t) {
    final u = t.toUtc();
    return '${formatDate(u)}T${_two(u.hour)}${_two(u.minute)}'
        '${_two(u.second)}Z';
  }

  /// A relative alarm TRIGGER: how far *before* the event to ring.
  ///
  /// RFC 5545 durations are `[+|-]P[nD][T[nH][nM][nS]]`. A non-positive lead
  /// time means "at the moment of the event", which is `PT0S` and not `-PT0S`.
  static String formatTrigger(Duration before) {
    if (before <= Duration.zero) return 'PT0S';
    final days = before.inDays;
    final hours = before.inHours % 24;
    final minutes = before.inMinutes % 60;
    final seconds = before.inSeconds % 60;

    final buf = StringBuffer('-P');
    if (days > 0) buf.write('${days}D');
    if (hours > 0 || minutes > 0 || seconds > 0) {
      buf.write('T');
      if (hours > 0) buf.write('${hours}H');
      if (minutes > 0) buf.write('${minutes}M');
      if (seconds > 0) buf.write('${seconds}S');
    }
    return buf.toString();
  }

  /// §3.3.11 TEXT escaping. Order matters: backslash first, or the escapes we
  /// add would themselves be escaped.
  static String _escape(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAll(';', '\\;')
      .replaceAll(',', '\\,')
      .replaceAll('\r\n', '\\n')
      .replaceAll('\n', '\\n')
      .replaceAll('\r', '\\n');

  /// Visible for testing.
  static String escapeText(String value) => _escape(value);

  /// §3.1 line folding: no content line may exceed 75 octets, and a fold is
  /// CRLF followed by a single space (which itself counts toward the next
  /// line's 75).
  ///
  /// Counted in **octets, not characters** — a name written in Devanagari or
  /// with an accent is multi-byte, and folding by character count produces
  /// lines that are legal-looking and over the limit. The split point also
  /// backs off any UTF-8 continuation byte, so a fold never lands mid-codepoint
  /// and turns a name into mojibake.
  static String foldLine(String line) {
    final bytes = utf8.encode(line);
    if (bytes.length <= 75) return line;

    final out = StringBuffer();
    var start = 0;
    var limit = 75;
    while (bytes.length - start > limit) {
      var end = start + limit;
      // 0b10xxxxxx is a continuation byte: walk back to the codepoint boundary.
      while (end > start + 1 && (bytes[end] & 0xC0) == 0x80) {
        end--;
      }
      out
        ..write(utf8.decode(bytes.sublist(start, end)))
        ..write('$crlf ');
      start = end;
      limit = 74; // the leading space occupies one of the 75 octets
    }
    out.write(utf8.decode(bytes.sublist(start)));
    return out.toString();
  }

  /// A filename-safe `.ics` name.
  static String filename({DateTime? now}) {
    final t = now ?? DateTime.now();
    return 'lumos-deadlines-${formatDate(t)}.ics';
  }

  /// Builds the calendar and hands it to the browser as a download.
  ///
  /// Returns false where there is nothing to export or no browser to download
  /// into (a non-web target), so the caller can say so rather than appearing to
  /// have done something.
  static bool download(
    List<ScheduledReminder> reminders, {
    DateTime? now,
    String? name,
  }) {
    if (reminders.isEmpty) return false;
    return downloadIcs(build(reminders, now: now), name ?? filename(now: now));
  }
}
