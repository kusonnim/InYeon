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

ThemeData itdaTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors =
      ColorScheme.fromSeed(
        seedColor: const Color(0xff586053),
        brightness: brightness,
      ).copyWith(
        surface: dark ? const Color(0xff232220) : const Color(0xfff8f6f0),
        onSurface: dark ? const Color(0xfff0ebe1) : const Color(0xff25231f),
        onSurfaceVariant: dark
            ? const Color(0xffc5beb2)
            : const Color(0xff605b52),
        primary: dark ? const Color(0xffc9cfbd) : const Color(0xff4a5745),
        onPrimary: dark ? const Color(0xff282d24) : const Color(0xfffaf7ef),
        primaryContainer: dark
            ? const Color(0xff394338)
            : const Color(0xffe1e7d8),
        onPrimaryContainer: dark
            ? const Color(0xffdce4d4)
            : const Color(0xff3b4937),
        surfaceContainerLowest: dark
            ? const Color(0xff1d1c1a)
            : const Color(0xfffffdf7),
        surfaceContainerLow: dark
            ? const Color(0xff2b2926)
            : const Color(0xfff2eee5),
        surfaceContainer: dark
            ? const Color(0xff302d29)
            : const Color(0xfff2eee5),
        surfaceContainerHigh: dark
            ? const Color(0xff36332e)
            : const Color(0xffeee9df),
        surfaceContainerHighest: dark
            ? const Color(0xff3c3934)
            : const Color(0xffeee9df),
        outline: dark ? const Color(0xff989084) : const Color(0xff898176),
        outlineVariant: dark
            ? const Color(0xff4e4942)
            : const Color(0xffddd6ca),
      );
  const target = Size.square(ItdaSpace.touchTarget);
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(ItdaSpace.small),
    borderSide: BorderSide(color: colors.outline),
  );
  final theme = ThemeData(
    colorScheme: colors,
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
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: target),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: target),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: target),
    ),
  );
  return theme.copyWith(
    textTheme: theme.textTheme.copyWith(
      headlineSmall: theme.textTheme.headlineSmall?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 1.25,
      ),
      titleLarge: theme.textTheme.titleLarge?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: theme.textTheme.titleMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.35,
      ),
      bodyMedium: theme.textTheme.bodyMedium?.copyWith(
        fontSize: 16,
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
