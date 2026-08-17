import 'package:flutter/material.dart';

import '../models/deadline.dart';
import '../services/deadline_service.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'pill_button.dart';

/// Adds a date the person already knows about — the one on the notice in their
/// hand that we could never have derived.
///
/// Two things it does not do, both on purpose: it does not require a date (a
/// titled reminder with no date is a valid, useful thing to keep), and it does
/// not require a *day* — "I only know the month" is a first-class answer, which
/// is the same rule onboarding follows.
Future<Deadline?> showAddDeadlineSheet(
  BuildContext context, {
  required DateTime now,
}) {
  return showDialog<Deadline>(
    context: context,
    builder: (context) => _AddDeadlineDialog(now: now),
  );
}

class _AddDeadlineDialog extends StatefulWidget {
  const _AddDeadlineDialog({required this.now});

  final DateTime now;

  @override
  State<_AddDeadlineDialog> createState() => _AddDeadlineDialogState();
}

class _AddDeadlineDialogState extends State<_AddDeadlineDialog> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  final _action = TextEditingController();

  bool _approximate = false;
  DateTime? _exact;
  int? _month;
  int? _year;

  @override
  void initState() {
    super.initState();
    _year = widget.now.year;
    _month = widget.now.month;
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    _action.dispose();
    super.dispose();
  }

  DateTime? get _due {
    if (_approximate) {
      final y = _year;
      final m = _month;
      if (y == null || m == null) return null;
      return DateTime(y, m, 1);
    }
    return _exact;
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    Navigator.of(context).pop(
      DeadlineService.compose(
        title: title,
        now: DateTime.now(),
        description: _note.text,
        dueDate: _due,
        isApproximate: _approximate,
        nextAction: _action.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.paper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(T.rCard),
      ),
      title: Text('Add a date', style: AppTheme.headingSm),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Anything you want kept in one place — a biometrics '
                'appointment, a card expiry, the day you promised to email your '
                'lawyer. It stays on this device.',
                style: AppTheme.bodySm,
              ),
              const SizedBox(height: T.s16),
              _Field(
                label: 'What is it?',
                controller: _title,
                hint: 'e.g. Renew my EAD card',
                autofocus: true,
              ),
              const SizedBox(height: T.s16),
              _Field(
                label: 'Anything worth remembering about it (optional)',
                controller: _note,
                hint: 'e.g. the receipt number is on the I-797',
                maxLines: 2,
              ),
              const SizedBox(height: T.s16),
              _Field(
                label: 'The next thing you need to do (optional)',
                controller: _action,
                hint: 'e.g. book the appointment',
              ),
              const SizedBox(height: T.s16),

              Text('When?', style: AppTheme.label),
              const SizedBox(height: T.s8),
              Row(
                children: [
                  Expanded(
                    child: PillButton(
                      label: _exact == null
                          ? 'Pick a day'
                          : '${_exact!.day}/${_exact!.month}/${_exact!.year}',
                      icon: Icons.calendar_today_outlined,
                      onPressed: _approximate
                          ? null
                          : () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: _exact ?? widget.now,
                                firstDate: DateTime(widget.now.year - 5),
                                lastDate: DateTime(widget.now.year + 15),
                              );
                              if (picked != null) {
                                setState(() => _exact = picked);
                              }
                            },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: T.s8),
              // Not knowing the exact day is normal, so it is a plain checkbox
              // rather than something you have to go looking for.
              CheckboxListTile(
                value: _approximate,
                onChanged: (v) => setState(() => _approximate = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
                activeColor: T.signalBlue,
                title: Text(
                  'I only know the month — don\'t pretend to know the day',
                  style: AppTheme.bodySm,
                ),
              ),
              if (_approximate)
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _month,
                        decoration: const InputDecoration(labelText: 'Month'),
                        items: [
                          for (var m = 1; m <= 12; m++)
                            DropdownMenuItem(
                              value: m,
                              child: Text(Deadline.monthName(m)),
                            ),
                        ],
                        onChanged: (v) => setState(() => _month = v),
                      ),
                    ),
                    const SizedBox(width: T.s16),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _year,
                        decoration: const InputDecoration(labelText: 'Year'),
                        items: [
                          for (
                            var y = widget.now.year - 1;
                            y <= widget.now.year + 10;
                            y++
                          )
                            DropdownMenuItem(value: y, child: Text('$y')),
                        ],
                        onChanged: (v) => setState(() => _year = v),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: T.s8),
              Text(
                'No date is fine too — it will sit under "no date yet".',
                style: AppTheme.caption,
              ),
            ],
          ),
        ),
      ),
      actions: [
        PillButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        PillButton(
          label: 'Add it',
          variant: PillVariant.signal,
          onPressed: _save,
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    this.hint,
    this.maxLines = 1,
    this.autofocus = false,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final int maxLines;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTheme.label),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          maxLines: maxLines,
          autofocus: autofocus,
          style: AppTheme.body.copyWith(color: T.ink),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: AppTheme.bodySm.copyWith(color: T.pencilGray),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(T.rInput),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
        ),
      ],
    );
  }
}
