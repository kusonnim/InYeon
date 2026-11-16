import 'dart:math' as math;

import 'package:flutter/material.dart';

abstract final class ItdaSpace {
  static const tiny = 4.0;
  static const small = 8.0;
  static const medium = 12.0;
  static const large = 16.0;
  static const page = 20.0;
  static const section = 24.0;
  static const bottom = 32.0;
  static const touchTarget = 48.0;
}

abstract final class ItdaPalette {
  static const brandBlue = Color(0xff0d70df);
  static const brightBlue = Color(0xff1598ff);
  static const paleBlue = Color(0xffe8f4ff);
  static const _deepBlue = Color(0xff075bba);
  static const _darkAccent = Color(0xff92c9ff);

  static Color homeHeader(Brightness brightness) =>
      brightness == Brightness.dark ? const Color(0xff144b9e) : brandBlue;

  static Color homeSearch(Brightness brightness) =>
      brightness == Brightness.dark ? const Color(0xff102440) : Colors.white;

  static Color traySurface(Brightness brightness) =>
      brightness == Brightness.dark ? const Color(0xff142d49) : paleBlue;

  // Keep each color family at its existing identity index.
  static const _lightPebbles = [
    Color(0xffbfd7f2),
    Color(0xffbfd8c8),
    Color(0xffdcc8b3),
    Color(0xffcecbe3),
    Color(0xffd6e6f8),
    Color(0xffc8d3b2),
  ];
  static const _darkPebbles = [
    Color(0xff6e8fb3),
    Color(0xff738f82),
    Color(0xff9a836e),
    Color(0xff8883a3),
    Color(0xff7c93b3),
    Color(0xff7f8b66),
  ];

  static const pebbleCount = 6;

  static Color pebble(Brightness brightness, int index) =>
      (brightness == Brightness.dark ? _darkPebbles : _lightPebbles)[index];

  static Color pebbleInk(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xff111923)
      : const Color(0xff18263a);
}

double itdaToolbarHeight(BuildContext context, {double? titleSize}) {
  final style = Theme.of(context).textTheme.titleLarge!;
  final size = MediaQuery.textScalerOf(
    context,
  ).scale(titleSize ?? style.fontSize!);
  return math.max(kToolbarHeight, size * style.height! + ItdaSpace.medium);
}

ThemeData itdaTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final canvas = dark ? const Color(0xff111923) : const Color(0xfff8fafd);
  final surface = dark ? const Color(0xff1b2635) : Colors.white;
  final secondarySurface = dark
      ? const Color(0xff253346)
      : const Color(0xfff1f5fa);
  final accent = dark ? ItdaPalette._darkAccent : ItdaPalette.brandBlue;
  final accentSurface = dark ? const Color(0xff213e60) : ItdaPalette.paleBlue;
  final ink = dark ? const Color(0xfff4f7fc) : const Color(0xff18263a);
  final muted = dark ? const Color(0xffb3c0d0) : const Color(0xff5c6c83);
  final onStrongColor = dark ? canvas : Colors.white;
  final colors = ColorScheme(
    brightness: brightness,
    primary: accent,
    onPrimary: onStrongColor,
    primaryContainer: accentSurface,
    onPrimaryContainer: dark ? accent : ItdaPalette._deepBlue,
    secondary: muted,
    onSecondary: onStrongColor,
    secondaryContainer: secondarySurface,
    onSecondaryContainer: ink,
    tertiary: dark ? const Color(0xff88ccb4) : const Color(0xff2f8067),
    onTertiary: onStrongColor,
    error: dark ? const Color(0xffffa8a8) : const Color(0xffb84646),
    onError: onStrongColor,
    surface: surface,
    surfaceDim: canvas,
    surfaceContainerLowest: canvas,
    surfaceContainerLow: surface,
    surfaceContainer: secondarySurface,
    surfaceContainerHigh: secondarySurface,
    surfaceContainerHighest: secondarySurface,
    onSurface: ink,
    onSurfaceVariant: muted,
    outline: dark ? const Color(0xff8193aa) : const Color(0xff75859b),
    outlineVariant: dark ? const Color(0xff39495c) : const Color(0xffe3e9f2),
    inverseSurface: dark ? const Color(0xfff4f7fc) : const Color(0xff18263a),
    onInverseSurface: onStrongColor,
    inversePrimary: dark ? ItdaPalette.brandBlue : ItdaPalette._darkAccent,
    surfaceTint: Colors.transparent,
  );
  const target = Size.square(ItdaSpace.touchTarget);
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(ItdaSpace.small),
    borderSide: BorderSide(color: colors.outline),
  );
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(ItdaSpace.medium),
  );
  final theme = ThemeData(
    colorScheme: colors,
    scaffoldBackgroundColor: canvas,
    fontFamily: 'SUIT',
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surface,
      foregroundColor: colors.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    dividerTheme: DividerThemeData(color: colors.outlineVariant, thickness: 1),
    inputDecorationTheme: InputDecorationThemeData(
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: colors.primary, width: 2),
      ),
      hintStyle: TextStyle(color: colors.onSurfaceVariant),
      prefixIconColor: WidgetStateColor.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? colors.primary
            : colors.onSurfaceVariant,
      ),
      suffixIconColor: colors.onSurfaceVariant,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: target, shape: buttonShape),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: target, shape: buttonShape),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: target),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      backgroundColor: surface,
      elevation: 0,
      indicatorColor: accent,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 23,
          color: states.contains(WidgetState.selected) ? onStrongColor : muted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: 'SUIT',
          fontSize: 13,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: states.contains(WidgetState.selected) ? accent : muted,
        ),
      ),
    ),
  );
  return theme.copyWith(
    textTheme: theme.textTheme.copyWith(
      headlineSmall: theme.textTheme.headlineSmall?.copyWith(
        fontSize: 26,
        fontWeight: FontWeight.w600,
        height: 1.25,
      ),
      titleLarge: theme.textTheme.titleLarge?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 1.25,
      ),
      titleMedium: theme.textTheme.titleMedium?.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        height: 1.35,
      ),
      titleSmall: theme.textTheme.titleSmall?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.35,
      ),
      bodyMedium: theme.textTheme.bodyMedium?.copyWith(
        fontSize: 14,
        height: 1.5,
      ),
      bodyLarge: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
      bodySmall: theme.textTheme.bodySmall?.copyWith(
        fontSize: 13,
        height: 1.4,
        color: colors.onSurfaceVariant,
      ),
      labelLarge: theme.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
