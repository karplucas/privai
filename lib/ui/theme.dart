import 'package:flutter/material.dart';

/// The app's visual language: a near-black canvas with a single indigo-to-sky
/// gradient used for anything that belongs to the user or invites a tap.
///
/// Everything visual is defined here rather than at the call sites, so the two
/// screens only ever ask for `Theme.of(context)` or [AppGradients.of].
abstract final class AppTheme {
  /// The one accent the whole app is built around.
  static const Color accent = Color(0xFF3D8BFF);
  static const Color accentSoft = Color(0xFF5B5BF0);

  // The neutrals carry a slight blue cast so the greys sit with the accent
  // rather than looking washed out beside it.
  static const Color _darkBackground = Color(0xFF080A0F);
  static const Color _darkSurface = Color(0xFF141821);
  static const Color _darkSurfaceHigh = Color(0xFF1E2430);
  static const Color _darkOutline = Color(0xFF2F3846);
  static const Color _darkText = Color(0xFFECEFF5);
  static const Color _darkMutedText = Color(0xFF919BAC);

  static const Color _lightBackground = Color(0xFFF7F9FC);
  static const Color _lightSurface = Color(0xFFFFFFFF);
  static const Color _lightSurfaceHigh = Color(0xFFEDF1F7);
  static const Color _lightOutline = Color(0xFFD5DDE8);
  static const Color _lightText = Color(0xFF14181F);
  static const Color _lightMutedText = Color(0xFF64707F);

  /// Corner radius shared by bubbles, cards and the composer.
  static const double radius = 22;

  static ThemeData dark() => _build(
        const ColorScheme.dark(
          primary: accent,
          onPrimary: Colors.white,
          primaryContainer: Color(0xFF17263F),
          onPrimaryContainer: Color(0xFFD3E6FF),
          secondary: accentSoft,
          onSecondary: Colors.white,
          surface: _darkBackground,
          onSurface: _darkText,
          surfaceContainerLowest: _darkBackground,
          surfaceContainer: _darkSurface,
          surfaceContainerHigh: _darkSurface,
          surfaceContainerHighest: _darkSurfaceHigh,
          onSurfaceVariant: _darkMutedText,
          outline: _darkOutline,
          outlineVariant: Color(0xFF212734),
          error: Color(0xFFFF6E8A),
          onError: Color(0xFF3A0512),
          errorContainer: Color(0xFF3A1420),
          onErrorContainer: Color(0xFFFFD3DC),
        ),
        muted: _darkMutedText,
        bubble: _darkSurface,
        hairline: const Color(0xFF212734),
      );

  static ThemeData light() => _build(
        const ColorScheme.light(
          primary: accent,
          onPrimary: Colors.white,
          primaryContainer: Color(0xFFDCEAFF),
          onPrimaryContainer: Color(0xFF0A2647),
          secondary: accentSoft,
          onSecondary: Colors.white,
          surface: _lightBackground,
          onSurface: _lightText,
          surfaceContainerLowest: _lightBackground,
          surfaceContainer: _lightSurface,
          surfaceContainerHigh: _lightSurface,
          surfaceContainerHighest: _lightSurfaceHigh,
          onSurfaceVariant: _lightMutedText,
          outline: _lightOutline,
          outlineVariant: Color(0xFFE3E9F1),
          error: Color(0xFFB3213E),
          onError: Colors.white,
          errorContainer: Color(0xFFFFE1E7),
          onErrorContainer: Color(0xFF4A0A1A),
        ),
        muted: _lightMutedText,
        bubble: _lightSurface,
        hairline: const Color(0xFFE3E9F1),
      );

  static ThemeData _build(
    ColorScheme scheme, {
    required Color muted,
    required Color bubble,
    required Color hairline,
  }) {
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
    );

    return base.copyWith(
      extensions: [
        AppGradients(
          accent: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF5B5BF0), Color(0xFF35B8FF)],
          ),
          // A shade deeper than the button gradient, so a bubble and the send
          // button beside it do not read as the same object.
          bubble: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF4B54E8), Color(0xFF2FA0FF)],
          ),
          bubbleColor: bubble,
          hairline: hairline,
        ),
      ],
      textTheme: base.textTheme
          .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface)
          .copyWith(
            titleLarge: base.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
            titleMedium: base.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
            titleSmall: base.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.45),
            bodySmall: base.textTheme.bodySmall?.copyWith(color: muted),
          ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleMedium?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
      dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),
      cardTheme: CardThemeData(
        color: bubble,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: hairline),
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: muted,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        selectedColor: scheme.primary,
        selectedTileColor: scheme.primary.withValues(alpha: 0.10),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        hintStyle: TextStyle(color: muted),
        labelStyle: TextStyle(color: muted),
        helperStyle: TextStyle(color: muted, fontSize: 12),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: hairline),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? Colors.white : muted),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.surfaceContainerHighest),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? Colors.transparent
                : hairline),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? scheme.primary : muted),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        contentTextStyle: TextStyle(color: scheme.onSurface),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
    );
  }
}

/// The gradients and hairline rule that the flat [ColorScheme] cannot carry.
@immutable
class AppGradients extends ThemeExtension<AppGradients> {
  const AppGradients({
    required this.accent,
    required this.bubble,
    required this.bubbleColor,
    required this.hairline,
  });

  /// For buttons, avatars and anything that should read as "tap me".
  final LinearGradient accent;

  /// For the user's own message bubbles.
  final LinearGradient bubble;

  /// Flat fill for assistant bubbles and cards.
  final Color bubbleColor;

  /// The 1 px rule separating surfaces on a near-black canvas.
  final Color hairline;

  static AppGradients of(BuildContext context) =>
      Theme.of(context).extension<AppGradients>()!;

  @override
  AppGradients copyWith({
    LinearGradient? accent,
    LinearGradient? bubble,
    Color? bubbleColor,
    Color? hairline,
  }) =>
      AppGradients(
        accent: accent ?? this.accent,
        bubble: bubble ?? this.bubble,
        bubbleColor: bubbleColor ?? this.bubbleColor,
        hairline: hairline ?? this.hairline,
      );

  @override
  AppGradients lerp(AppGradients? other, double t) {
    if (other == null) return this;
    return AppGradients(
      accent: LinearGradient.lerp(accent, other.accent, t)!,
      bubble: LinearGradient.lerp(bubble, other.bubble, t)!,
      bubbleColor: Color.lerp(bubbleColor, other.bubbleColor, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
    );
  }
}

/// The gradient badge that stands in for the assistant throughout the app.
class SparkAvatar extends StatelessWidget {
  const SparkAvatar(
      {super.key, this.size = 34, this.icon = Icons.auto_awesome});

  final double size;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppGradients.of(context).accent,
      ),
      child: Icon(icon, size: size * 0.52, color: Colors.white),
    );
  }
}

/// A circular button filled with the accent gradient.
class GradientIconButton extends StatelessWidget {
  const GradientIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 40,
    this.glow = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;

  /// Casts the accent as a soft halo — used for the microphone, which is the
  /// one control that should pull the eye.
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final gradient = AppGradients.of(context).accent;

    final button = Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: gradient,
          boxShadow: glow && enabled
              ? [
                  BoxShadow(
                    color: AppTheme.accent.withValues(alpha: 0.45),
                    blurRadius: size * 0.5,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Center(
              child: Icon(icon, size: size * 0.48, color: Colors.white),
            ),
          ),
        ),
      ),
    );

    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
