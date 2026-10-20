import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../state/discover_state.dart';
import 'kit.dart';
import 'tabs/discover_tab.dart';
import 'tabs/leaderboard_tab.dart';
import 'tabs/library_tab.dart';
import 'tabs/search_tab.dart';
import 'widgets/mini_player.dart';

/// Height left free at the bottom of tab scrolls for the floating chrome.
const double kRootChromeSpace = 160;

/// Visual height of the tab bar row, excluding the bottom safe-area inset.
/// Tall enough that each tab is a comfortable thumb target.
const double kTabBarHeight = 62;

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  // 歌单 (DiscoverTab) is index 1 — the app opens there instead of search.
  int _index = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<DiscoverState>().init().catchError((_) {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: <Widget>[
          const Positioned.fill(child: AuroraBackground()),
          // The aurora chrome (tab bar, pendant) spans the window, but the
          // content column stays readable on a tablet or an unfolded foldable
          // instead of stretching one song row across the whole screen.
          Positioned.fill(
            child: Align(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: kAuroraContentMaxWidth,
                ),
                child: SizedBox.expand(
                  child: IndexedStack(
                    index: _index,
                    children: const <Widget>[
                      SearchTab(),
                      DiscoverTab(),
                      LeaderboardTab(),
                      LibraryTab(),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Floating now-playing pendant. It manages its own Positioned so the
          // user can drag it anywhere (see MiniPlayer).
          MiniPlayer(
            bottomReserved:
                kTabBarHeight + MediaQuery.paddingOf(context).bottom + 12,
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // Soft fade so rows dissolve under the chrome (.root-chrome).
                Container(
                  height: 26,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        Colors.transparent,
                        bgFor(context).withValues(alpha: 0.85),
                        bgFor(context),
                      ],
                      stops: const <double>[0, 0.55, 1],
                    ),
                  ),
                ),
                _AuroraTabBar(
                  index: _index,
                  onTap: (next) => setState(() => _index = next),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AuroraTabBar extends StatelessWidget {
  const _AuroraTabBar({required this.index, required this.onTap});

  final int index;
  final ValueChanged<int> onTap;

  static const List<Map<String, Object>> _tabs = <Map<String, Object>>[
    <String, Object>{'icon': CupertinoIcons.search, 'label': '搜索'},
    <String, Object>{'icon': CupertinoIcons.music_albums, 'label': '歌单'},
    <String, Object>{'icon': CupertinoIcons.chart_bar, 'label': '排行榜'},
    <String, Object>{'icon': CupertinoIcons.rectangle_stack, 'label': '我的'},
  ];

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          decoration: BoxDecoration(
            color: surfaceFor(context),
            border: Border(top: BorderSide(color: lineColor(context))),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              child: Row(
                children: List<Widget>.generate(_tabs.length, (i) {
                  final tab = _tabs[i];
                  final active = i == index;
                  return Expanded(
                    child: Pressable(
                      onTap: () => onTap(i),
                      child: SizedBox(
                        height: kTabBarHeight - 12,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            Container(
                              width: 46,
                              height: 30,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(999),
                                color: active
                                    ? accentSoftColor(context)
                                    : Colors.transparent,
                              ),
                              child: Icon(
                                tab['icon'] as IconData,
                                size: 22,
                                color: active ? accentFor(context) : faintFor(context),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              tab['label'] as String,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: active ? accentFor(context) : faintFor(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
