import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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
