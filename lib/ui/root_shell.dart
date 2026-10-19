import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../state/discover_state.dart';
import 'tabs/discover_tab.dart';
import 'tabs/leaderboard_tab.dart';
import 'tabs/library_tab.dart';
import 'tabs/search_tab.dart';
import 'widgets/mini_player.dart';

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: IndexedStack(
        index: _index,
        children: const <Widget>[
          SearchTab(),
          DiscoverTab(),
          LeaderboardTab(),
          LibraryTab(),
        ],
      ),
      bottomNavigationBar: Container(
        color: isDark ? AppColors.darkBackground : AppColors.lightBackground,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const MiniPlayer(),
            Container(
              color: surfaceFor(context),
              child: SafeArea(
                top: false,
                child: CupertinoTabBar(
                  currentIndex: _index,
                  onTap: (index) => setState(() => _index = index),
                  activeColor: AppColors.accent,
                  inactiveColor: mutedFor(context),
                  backgroundColor: surfaceFor(context),
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).dividerColor.withValues(alpha: 0.6),
                    ),
                  ),
                  items: const <BottomNavigationBarItem>[
                    BottomNavigationBarItem(
                      icon: Icon(Icons.search_rounded),
                      activeIcon: Icon(Icons.search_rounded),
                      label: '搜索',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.grid_view_rounded),
                      activeIcon: Icon(Icons.grid_view_rounded),
                      label: '歌单',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.leaderboard_rounded),
                      activeIcon: Icon(Icons.leaderboard_rounded),
                      label: '排行榜',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.library_music_rounded),
                      activeIcon: Icon(Icons.library_music_rounded),
                      label: '我的',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
