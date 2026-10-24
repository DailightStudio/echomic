import 'package:flutter/material.dart';

import 'analytics.dart';
import 'home_screen.dart';
import 'ui_colors.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Analytics.init();
  runApp(const EchomicApp());
}

class EchomicApp extends StatelessWidget {
  const EchomicApp({super.key});

  static ThemeData _theme() {
    final cs = ColorScheme.fromSeed(
      seedColor: kNeonA,
      brightness: Brightness.dark,
    ).copyWith(
      surface: kStageBg,
      surfaceContainer: const Color(0xFF17121F),
      surfaceContainerHigh: const Color(0xFF1F1829),
      surfaceContainerHighest: const Color(0xFF2A2236),
    );
    return ThemeData(
      colorScheme: cs,
      useMaterial3: true,
      scaffoldBackgroundColor: cs.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        foregroundColor: cs.onSurface,
        titleTextStyle: TextStyle(
            fontSize: 18, fontWeight: FontWeight.w600, color: cs.onSurface),
      ),
      cardTheme: CardThemeData(
        color: cs.surfaceContainer,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 4,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 9),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 18),
        activeTrackColor: kNeonA,
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        selectedColor: kNeonA.withValues(alpha: 0.25),
        side: WidgetStateBorderSide.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? const BorderSide(color: kNeonA)
                : BorderSide(color: cs.outlineVariant)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '에코마이크',
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      home: const HomeScreen(),
    );
  }
}
