import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'features/local_setup_view.dart';
import 'features/remote_panels_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FLSApp());
}

class FLSApp extends StatelessWidget {
  const FLSApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FLS',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomeShell(),
    );
  }
}

ThemeData _buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  const lightPrimary = Color(0xFF3964FE);
  const darkPrimary = Color(0xFF5686FE);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: isDark ? darkPrimary : lightPrimary,
        brightness: brightness,
      ).copyWith(
        primary: isDark ? darkPrimary : lightPrimary,
        onPrimary: isDark ? const Color(0xFF0F1115) : Colors.white,
        primaryContainer: isDark
            ? const Color(0xFF283141)
            : const Color(0xFFEDF3FE),
        onPrimaryContainer: isDark
            ? const Color(0xFFD3E2FF)
            : const Color(0xFF283141),
        secondary: isDark ? const Color(0xFFADB2B8) : const Color(0xFF61666B),
        tertiary: isDark ? const Color(0xFF4ED17E) : const Color(0xFF16803C),
        tertiaryContainer: isDark
            ? const Color(0xFF233C2C)
            : const Color(0xFFE6FAED),
        error: isDark ? const Color(0xFFF25A5A) : const Color(0xFFEC1313),
        errorContainer: isDark
            ? const Color(0xFF3A2020)
            : const Color(0xFFFFEEEE),
        onErrorContainer: isDark
            ? const Color(0xFFFFDAD6)
            : const Color(0xFF7B1717),
        surface: isDark ? const Color(0xFF1B1B1C) : Colors.white,
        surfaceContainerLowest: isDark ? const Color(0xFF151517) : Colors.white,
        surfaceContainerLow: isDark
            ? const Color(0xFF1B1B1C)
            : const Color(0xFFF9FAFB),
        surfaceContainer: isDark
            ? const Color(0xFF212123)
            : const Color(0xFFF5F6F7),
        surfaceContainerHigh: isDark
            ? const Color(0xFF2C2C2E)
            : const Color(0xFFF1F3F5),
        surfaceContainerHighest: isDark
            ? const Color(0xFF353638)
            : const Color(0xFFEBEEF2),
        onSurface: isDark ? const Color(0xFFEBEEF2) : const Color(0xFF0F1115),
        onSurfaceVariant: isDark
            ? const Color(0xFFADB2B8)
            : const Color(0xFF61666B),
        outline: isDark ? const Color(0xFF676A70) : const Color(0xFFADB2B8),
        outlineVariant: isDark
            ? const Color(0xFF353638)
            : const Color(0xFFE1E5EE),
      );
  final mutedBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(color: scheme.outlineVariant),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surfaceContainerLow,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surfaceContainerLow,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      border: mutedBorder,
      enabledBorder: mutedBorder,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
      elevation: 0,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        );
      }),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
  );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [const RemotePanelsView(), LocalSetupView()];
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(index: _selectedIndex, children: pages),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          HapticFeedback.selectionClick();
          setState(() => _selectedIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dns_outlined),
            selectedIcon: Icon(Icons.dns),
            label: '远程面板',
          ),
          NavigationDestination(
            icon: Icon(Icons.phone_android_outlined),
            selectedIcon: Icon(Icons.phone_android),
            label: '本机面板',
          ),
        ],
      ),
    );
  }
}
