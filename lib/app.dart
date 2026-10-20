import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/theme.dart';
import 'state/app_state.dart';
import 'ui/engine_host.dart';
import 'ui/root_shell.dart';

class FlmApp extends StatelessWidget {
  const FlmApp({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final effectiveBrightness = switch (appState.settings.themeMode) {
      'light' => Brightness.light,
      'dark' => Brightness.dark,
      _ => brightness,
    };
    return MaterialApp(
      title: 'flm',
      debugShowCheckedModeBanner: false,
      themeMode: appState.themeMode,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      scrollBehavior: const AuroraScrollBehavior(),
      builder: (context, child) {
        final content = child ?? const SizedBox.shrink();
        final media = MediaQuery.of(context);
        // Android ships a user-controlled font scale, and 1.3x is a common
        // setting on the bigger phones. The layout's rows, pills and the
        // pendant are sized for the design's own type ramp, so the scale is
        // allowed to grow a little — enough to stay readable, not enough to
        // push text out of a 56dp song row.
        final scaled = MediaQuery(
          data: media.copyWith(
            textScaler: media.textScaler.clamp(
              minScaleFactor: 1.0,
              maxScaleFactor: 1.25,
            ),
          ),
          child: content,
        );
        // Edge-to-edge on Android and the notch on iOS both put the status bar
        // over the artwork; the icons have to follow the appearance.
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: effectiveBrightness == Brightness.dark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          child: scaled,
        );
      },
      home: EngineHost(
        child: Builder(
          builder: (context) {
            return CupertinoTheme(
              data: buildCupertinoTheme(effectiveBrightness),
              child: const RootShell(),
            );
          },
        ),
      ),
    );
  }
}
