import 'package:flutter/material.dart';

import 'tokens.dart';

/// Inter is the single family in the system. Display sizes carry tight tracking
/// (-0.036em … -0.06em) so headlines compress into a typographic block; body
/// copy never exceeds 18px or weight 500.
class AppTheme {
  const AppTheme._();

  /// Bundled in `assets/fonts` — see pubspec.
  static const fontFamily = 'Inter';

  static TextStyle inter(
    double size, {
    FontWeight weight = FontWeight.w400,
    double height = 1.5,
    double tracking = 0,
    Color color = T.ink,
  }) => TextStyle(
    fontFamily: fontFamily,
    fontSize: size,
    fontWeight: weight,
    height: height,
    letterSpacing: tracking * size,
    color: color,
  );

  static TextStyle _inter(
    double size, {
    FontWeight weight = FontWeight.w400,
    double height = 1.5,
    double tracking = 0,
    Color color = T.ink,
  }) => inter(
    size,
    weight: weight,
    height: height,
    tracking: tracking,
    color: color,
  );

  // Named roles from the type scale.
  /// Capped below the 118px token so the hero animation still clears the fold
  /// on a laptop viewport.
  static TextStyle displayXl(BuildContext c) => _inter(
    Breaks.isMobile(c) ? 30 : (Breaks.isTablet(c) ? 44 : 50),
    weight: FontWeight.w700,
    height: 0.80,
    tracking: -0.052,
  );
  static TextStyle displayX2(BuildContext c) => _inter(
    Breaks.isMobile(c) ? 30 : (Breaks.isTablet(c) ? 44 : 50),
    weight: FontWeight.w600,
    height: 0.80,
    tracking: -0.052,
  );
  static TextStyle display(BuildContext c) => _inter(
    Breaks.isMobile(c) ? 36 : 72,
    weight: FontWeight.w700,
    height: 1.0,
    tracking: -0.053,
  );
  static TextStyle headingLg(BuildContext c) => _inter(
    Breaks.isMobile(c) ? 32 : 40,
    weight: FontWeight.w700,
    height: 1.0,
    tracking: -0.036,
  );
  static TextStyle heading(BuildContext c) => _inter(
    Breaks.isMobile(c) ? 26 : 36,
    weight: FontWeight.w700,
    height: 1.14,
    tracking: -0.03,
  );
  static final headingSm = _inter(
    24,
    weight: FontWeight.w600,
    height: 1.3,
    tracking: -0.02,
  );
  static final subheading = _inter(
    18,
    weight: FontWeight.w400,
    height: 1.4,
    tracking: -0.02,
    color: T.graphite,
  );
  static final body = _inter(
    16,
    height: 1.5,
    tracking: -0.015,
    color: T.graphite,
  );
  static final bodyHighlight = _inter(
    16,
    height: 1.5,
    tracking: -0.015,
    color: const Color.fromARGB(255, 39, 144, 248),
  );
  static final bodySm = _inter(
    14,
    height: 1.43,
    tracking: -0.015,
    color: T.graphite,
  );

  /// Captions carry real information (deadline counts, form numbers, legal
  /// notices), so they are held to the 4.5:1 body-text bar. Pencil Gray on
  /// white measures 2.84:1 and fails it; Graphite measures 5.13:1 and reads as
  /// the same quiet grey. Pencil Gray survives as a *border* token only.
  static final caption = _inter(12, height: 1.4, color: T.graphite);
  static final label = _inter(14, weight: FontWeight.w500, color: T.carbon);
  static final badge = _inter(
    11,
    weight: FontWeight.w600,
    height: 1.2,
    color: T.ink,
  );

  static ThemeData build() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: T.paper,
      colorScheme: const ColorScheme.light(
        primary: T.signalBlue,
        onPrimary: T.paper,
        surface: T.paper,
        onSurface: T.ink,
        outline: T.pencilGray,
      ),
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: T.ink, displayColor: T.ink),
      splashFactory: InkRipple.splashFactory,
      dividerTheme: const DividerThemeData(
        color: T.pencilGray,
        thickness: 1,
        space: 1,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: T.ink,
          borderRadius: BorderRadius.circular(T.rNav),
        ),
        textStyle: inter(12, color: T.paper, weight: FontWeight.w500),
      ),
    );
  }
}
