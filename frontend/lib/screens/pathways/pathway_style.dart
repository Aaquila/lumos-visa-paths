import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// Per-category accents. The page stays monochrome + Signal Blue for anything
/// interactive; these pastels are chips only, never lines or buttons.
class CategoryStyle {
  const CategoryStyle(this.fill, this.icon);

  final Color fill;
  final IconData icon;

  static const _fallback = CategoryStyle(T.pastelSky, Icons.circle_outlined);

  static const _byId = <String, CategoryStyle>{
    'student': CategoryStyle(T.pastelYellow, Icons.school_outlined),
    'exchange': CategoryStyle(T.pastelMint, Icons.swap_horiz),
    'temp_worker': CategoryStyle(T.pastelSky, Icons.work_outline),
    'intracompany': CategoryStyle(T.pastelLavender, Icons.apartment_outlined),
    'extraordinary': CategoryStyle(T.pastelPink, Icons.star_outline),
    'family_temp': CategoryStyle(T.pastelPeach, Icons.favorite_outline),
    'employment_gc': CategoryStyle(T.pastelSky, Icons.badge_outlined),
    'family_gc': CategoryStyle(T.pastelPink, Icons.family_restroom_outlined),
    'diversity': CategoryStyle(T.pastelLavender, Icons.casino_outlined),
    'humanitarian': CategoryStyle(T.pastelMint, Icons.shield_outlined),
    'special_immigrant': CategoryStyle(
      T.pastelPeach,
      Icons.volunteer_activism_outlined,
    ),
    'post_lpr': CategoryStyle(T.pastelYellow, Icons.flag_outlined),
  };

  static CategoryStyle of(String categoryId) => _byId[categoryId] ?? _fallback;
}

/// Human-readable labels for the edge `type` field in the pathway JSON.
String edgeTypeLabel(String type) => switch (type) {
  'authorization' => 'Work authorisation',
  'extension' => 'Extension',
  'change_of_status' => 'Change of status',
  'employer_change' => 'Employer change',
  'petition' => 'Petition',
  'adjustment' => 'Adjustment of status',
  'adjustment_or_consular' => 'Adjustment or consular',
  'condition_removal' => 'Removal of conditions',
  'priority_date_transfer' => 'Keeps your priority date',
  'auto_upgrade' => 'Automatic upgrade',
  'auto_convert' => 'Automatic conversion',
  'life_event' => 'Life event',
  'filing' => 'Filing',
  'eligibility' => 'Eligibility',
  _ => type.replaceAll('_', ' '),
};

String phaseLabel(int phase) => switch (phase) {
  0 => 'Modelled now',
  1 => 'Coming in phase 1',
  2 => 'Coming in phase 2',
  _ => 'Not yet modelled',
};
