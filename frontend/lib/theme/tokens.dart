import 'package:flutter/material.dart';

/// Design tokens transcribed from `frontend/docs/DESIGN_flowmapp_landing_page.md`.
///
/// The system is deliberately monochrome: white canvas, black type, and a single
/// saturated blue that means "action". The pastel set is the one sanctioned
/// exception — it is only ever used for small circular icon badges and node
/// category chips, never for buttons or links.
class T {
  const T._();

  // ── Colors ────────────────────────────────────────────────────────────────
  static const signalBlue = Color(0xFF0080FF);
  static const voltageViolet = Color(0xFF0050FF);
  static const skyWash = Color(0xFFC5E0FB);
  static const pencilGray = Color(0xFF8C9BAA);
  static const graphite = Color(0xFF636F7B);
  static const ink = Color(0xFF000000);
  static const carbon = Color(0xFF222222);
  static const paper = Color(0xFFFFFFFF);

  /// Pastel icon-badge fills — inline accents only.
  static const pastelYellow = Color(0xFFFFF3C4);
  static const pastelMint = Color(0xFFC8F0D8);
  static const pastelPink = Color(0xFFFFD6E0);
  static const pastelLavender = Color(0xFFE0D4FF);
  static const pastelPeach = Color(0xFFFFE0C4);
  static const pastelSky = Color(0xFFD6E9FF);

  // ── Spacing (8px base) ────────────────────────────────────────────────────
  static const s8 = 8.0;
  static const s16 = 16.0;
  static const s24 = 24.0;
  static const s32 = 32.0;
  static const s40 = 40.0;
  static const s48 = 48.0;
  static const s56 = 56.0;
  static const s64 = 64.0;
  static const s72 = 72.0;
  static const s80 = 80.0;
  static const s96 = 96.0;
  static const s144 = 144.0;

  // ── Layout ────────────────────────────────────────────────────────────────
  static const pageMaxWidth = 1200.0;
  static const sectionGap = 96.0;
  static const cardPadding = 24.0;

  // ── Radii ─────────────────────────────────────────────────────────────────
  static const rNav = 6.0;
  static const rInput = 12.0;
  static const rCard = 20.0;
  static const rImage = 24.0;
  static const rFeatureCard = 32.0;

  /// The signature full pill.
  static const rPill = 1600.0;

  // ── Elevation ─────────────────────────────────────────────────────────────
  /// The only shadow in the system — floating mockups and modals.
  static const List<BoxShadow> floatShadow = [
    BoxShadow(color: Color(0x0F000000), blurRadius: 18),
  ];

  /// Hero CTA glow (Sky Wash at 60%).
  static const List<BoxShadow> ctaGlow = [
    BoxShadow(color: Color(0x99C5E0FB), blurRadius: 18),
  ];

  static const hairline = BorderSide(color: pencilGray, width: 1);
}

/// Breakpoints. The design is max-width contained, so these only decide when
/// two-column blocks collapse and when display type steps down.
class Breaks {
  const Breaks._();
  static const mobile = 720.0;
  static const tablet = 1040.0;

  static bool isMobile(BuildContext c) => MediaQuery.sizeOf(c).width < mobile;
  static bool isTablet(BuildContext c) => MediaQuery.sizeOf(c).width < tablet;
}

/// Motion policy.
///
/// The audience this product is built for includes people with vestibular and
/// motion sensitivity, so every decorative animation in the app has to be able
/// to switch itself off. On the web Flutter maps the browser's
/// `prefers-reduced-motion: reduce` onto [MediaQueryData.disableAnimations],
/// which is also what the OS-level "reduce motion" setting sets on desktop and
/// mobile — so one check covers all of them.
///
/// Rule: reduced motion never removes information. Looping and decorative
/// animation stops outright; state-change animation collapses to its final
/// frame instantly rather than being skipped.
class Motion {
  const Motion._();

  /// True when the user has asked the platform for reduced motion.
  static bool reduced(BuildContext c) =>
      MediaQuery.maybeDisableAnimationsOf(c) ?? false;

  /// [d], or [Duration.zero] when the user has asked for reduced motion — so an
  /// `AnimatedContainer` jumps straight to its final state instead of easing.
  static Duration duration(BuildContext c, Duration d) =>
      reduced(c) ? Duration.zero : d;
}
