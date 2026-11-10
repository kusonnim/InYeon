import 'package:flutter/material.dart';

ThemeData itdaTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors = ColorScheme.fromSeed(
    seedColor: const Color(0xff586053),
    brightness: brightness,
  ).copyWith(
    surface: dark ? const Color(0xff232220) : const Color(0xfff8f6f0),
    onSurface: dark ? const Color(0xfff0ebe1) : const Color(0xff25231f),
    onSurfaceVariant: dark ? const Color(0xffc5beb2) : const Color(0xff605b52),
    primary: dark ? const Color(0xffc9cfbd) : const Color(0xff4a5745),
    onPrimary: dark ? const Color(0xff282d24) : const Color(0xfffaf7ef),
    primaryContainer: dark ? const Color(0xff394338) : const Color(0xffe1e7d8),
    onPrimaryContainer:
        dark ? const Color(0xffdce4d4) : const Color(0xff3b4937),
    surfaceContainerLow:
        dark ? const Color(0xff2b2926) : const Color(0xfff2eee5),
    surfaceContainerHighest:
        dark ? const Color(0xff3c3934) : const Color(0xffeee9df),
    outline: dark ? const Color(0xff989084) : const Color(0xff898176),
    outlineVariant: dark ? const Color(0xff4e4942) : const Color(0xffddd6ca),
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
    cardTheme: CardThemeData(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
  );
  return theme.copyWith(
    textTheme: theme.textTheme.copyWith(
      headlineLarge: theme.textTheme.headlineLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      headlineMedium: theme.textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      titleLarge: theme.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      titleMedium: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
      bodyLarge: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
    ),
  );
}
