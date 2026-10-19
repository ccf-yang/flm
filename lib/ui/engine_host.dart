import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/online_engine.dart';
import '../services/source_engine.dart';
import '../state/app_state.dart';
import '../state/player_state.dart';
import '../state/source_state.dart';

class EngineHost extends StatefulWidget {
  const EngineHost({super.key, required this.child});

  final Widget child;

  @override
  State<EngineHost> createState() => _EngineHostState();
}

class _EngineHostState extends State<EngineHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final online = context.read<OnlineEngine>();
      final sourceState = context.read<SourceState>();
      online.load().catchError((_) {});
      sourceState.init().then((_) {
        if (!mounted) return;
        final appState = context.read<AppState>();
        final player = context.read<PlayerController>();
        if (appState.settings.autoPlayOnStart && player.current != null) {
          player.play();
        }
      }).catchError((_) {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final online = context.read<OnlineEngine>();
    final source = context.read<SourceEngine>();
    return Stack(
      children: <Widget>[
        widget.child,
        Positioned(
          left: 0,
          top: 0,
          width: 1,
          height: 1,
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.01,
              child: WebViewWidget(controller: online.controller),
            ),
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          width: 1,
          height: 1,
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.01,
              child: WebViewWidget(controller: source.controller),
            ),
          ),
        ),
      ],
    );
  }
}
