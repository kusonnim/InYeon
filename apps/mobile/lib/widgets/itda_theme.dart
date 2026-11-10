import 'package:flutter/material.dart';

ThemeData itdaTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors = ColorScheme.fromSeed(
    seedColor: const Color(0xff34694f),
    brightness: brightness,
  ).copyWith(
    surface: dark ? const Color(0xff141b17) : const Color(0xfff6f8f4),
    surfaceContainerLow: dark ? const Color(0xff202923) : Colors.white,
  );
  final theme = ThemeData(
    colorScheme: colors,
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colors.outlineVariant),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: colors.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
      headlineLarge:
          theme.textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w700),
      headlineMedium:
          theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
      titleLarge:
          theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium:
          theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      bodyMedium: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
      bodyLarge: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
    ),
  );
}
