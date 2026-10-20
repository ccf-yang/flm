import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../state/app_state.dart';
import '../../state/discover_state.dart';
import '../kit.dart';
import '../root_shell.dart' show kRootChromeSpace;
import '../screens/leaderboard_detail_screen.dart';
import '../widgets/cover_image.dart';
import '../widgets/empty_state.dart';
import '../widgets/source_chips.dart';

class LeaderboardTab extends StatelessWidget {
  const LeaderboardTab({super.key});

  @override
  Widget build(BuildContext context) {
    final discover = context.watch<DiscoverState>();
    final settings = context.watch<AppState>().settings;
    final top = MediaQuery.paddingOf(context).top + 10;

    void openBoard(Map<String, dynamic> board) {
      Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => LeaderboardDetailScreen(
            source: '${board['source'] ?? discover.leaderboardSource}',
            id: '${board['id'] ?? ''}',
            title: '${board['name'] ?? '排行榜'}',
            coverUrl: '${board['img'] ?? ''}',
          ),
        ),
      );
    }

    return Scaffold(
      body: CustomScrollView(
        slivers: <Widget>[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(kGutter, top, kGutter, 4),
            sliver: SliverToBoxAdapter(
              child: ScreenHead(
                overline: 'Rankings / 03',
                title: '排行榜',
                subtitle: '此刻，大家都在听什么。',
                trailing: IconBtn(
                  icon: CupertinoIcons.arrow_clockwise,
                  tooltip: '刷新',
                  onTap: discover.loadBoards,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SourceChips(
              value: discover.leaderboardSource,
              settings: settings,
              allowAggregate: false,
              onChanged: (value) {
                discover.setLeaderboardSource(value);
              },
            ),
          ),
          if (discover.boardsLoading && discover.boards.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 70),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                ),
              ),
            )
          else if (discover.boardsError != null && discover.boards.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 40),
                child: EmptyState(
                  title: '排行榜加载失败',
                  message: discover.boardsError,
                  icon: CupertinoIcons.chart_bar,
                  action: AuroraButton(label: '重试', onTap: discover.loadBoards),
                ),
              ),
            )
          else if (discover.boards.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 40),
                child: EmptyState(
                  title: '暂无排行榜',
                  message: '换个平台或稍后重试',
                  icon: CupertinoIcons.chart_bar,
                ),
              ),
            )
          else ...<Widget>[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(kGutter, 16, kGutter, 0),
              sliver: SliverToBoxAdapter(
                child: _BoardFeature(
                  board: discover.boards.first,
                  source: discover.leaderboardSource,
                  onTap: () => openBoard(discover.boards.first),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SectionHead(
                title: '全部榜单',
                note: '${discover.boards.length - 1} 个榜单',
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(kGutter, 2, kGutter - 7, 4),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final board = discover.boards[index + 1];
                    final lastBoard = index + 1 == discover.boards.length - 1;
                    return _BoardRow(
                      board: board,
                      rank: index + 2,
                      last: lastBoard,
                      onTap: () => openBoard(board),
                    );
                  },
                  childCount: discover.boards.length - 1,
                ),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: kRootChromeSpace)),
        ],
      ),
    );
  }
}

class _BoardRow extends StatelessWidget {
  const _BoardRow({
    required this.board,
    required this.rank,
    required this.onTap,
    this.last = false,
  });

  final Map<String, dynamic> board;
  final int rank;
  final VoidCallback onTap;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final image = '${board['img'] ?? ''}';
    final name = '${board['name'] ?? '排行榜'}';
    final update = '${board['update_frequency'] ?? board['updateFrequency'] ?? ''}';
    final topRank = rank <= 2;

    return Pressable(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 72),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border(
            bottom: last
                ? BorderSide.none
                : BorderSide(color: lineColor(context)),
          ),
        ),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 24,
              child: Text(
                rank.toString().padLeft(2, '0'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  color: topRank ? accentFor(context) : faintFor(context),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 52,
              height: 52,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  GradientArt(
                    seed: 'board:${board['id'] ?? ''}:$name',
                    radius: 13,
                    decorate: true,
                  ),
                  if (image.isNotEmpty)
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(13),
                        child: CoverImage(url: image),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: textFor(context),
                    ),
                  ),
                  if (update.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      update,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: faintFor(context)),
                    ),
                  ],
                ],
              ),
            ),
            Icon(CupertinoIcons.chevron_right, size: 14, color: faintFor(context)),
            const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }
}

class _BoardFeature extends StatelessWidget {
  const _BoardFeature({
    required this.board,
    required this.source,
    required this.onTap,
  });

  final Map<String, dynamic> board;
  final String source;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final image = '${board['img'] ?? ''}';
    final name = '${board['name'] ?? '排行榜'}';
    final update = '${board['update_frequency'] ?? board['updateFrequency'] ?? ''}';
    final count = '${board['count'] ?? ''}';

    return Pressable(
      onTap: onTap,
      child: Container(
        height: 172,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(23),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x59000000),
              blurRadius: 34,
              offset: Offset(0, 14),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            GradientArt(
              seed: 'board:$source:${board['id'] ?? ''}:$name',
              radius: 0,
              decorate: true,
            ),
            if (image.isNotEmpty)
              Positioned.fill(
                child: CoverImage(url: image),
              ),
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: <Color>[
                      Color(0xE605070A),
                      Color(0x5905070A),
                      Color(0x0005070A),
                    ],
                    stops: <double>[0, 0.62, 1],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 18,
              top: 18,
              bottom: 18,
              right: 70,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
                    ),
                    child: Text(
                      '$source · ${update.isEmpty ? '榜单' : update}'
                          .toUpperCase(),
                      style: const TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.04,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1.08,
                      color: Colors.white,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    <String>[
                      if (update.isNotEmpty) update,
                      if (count.isNotEmpty) count,
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: 9,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
