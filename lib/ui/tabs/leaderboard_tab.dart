import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../state/discover_state.dart';
import '../screens/leaderboard_detail_screen.dart';
import '../widgets/empty_state.dart';
import '../widgets/source_chips.dart';

class LeaderboardTab extends StatelessWidget {
  const LeaderboardTab({super.key});

  @override
  Widget build(BuildContext context) {
    final discover = context.watch<DiscoverState>();
    return Scaffold(
      appBar: AppBar(title: const Text('排行榜')),
      body: Column(
        children: <Widget>[
          SourceChips(
            value: discover.leaderboardSource,
            options: kSourceOptions.where((item) => item['id'] != 'all').toList(),
            onChanged: (value) {
              discover.setLeaderboardSource(value);
            },
          ),
          const SizedBox(height: 4),
          Expanded(child: _buildBody(context, discover)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, DiscoverState discover) {
    if (discover.boardsLoading && discover.boards.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (discover.boardsError != null && discover.boards.isEmpty) {
      return EmptyState(
        title: '排行榜加载失败',
        message: discover.boardsError,
        icon: Icons.leaderboard_outlined,
        action: FilledButton(
          onPressed: () {
            discover.loadBoards();
          },
          child: const Text('重试'),
        ),
      );
    }
    if (discover.boards.isEmpty) {
      return const EmptyState(title: '暂无排行榜', icon: Icons.leaderboard_outlined);
    }
    return RefreshIndicator(
      onRefresh: discover.loadBoards,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: discover.boards.length,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          indent: 84,
          color: Theme.of(context).dividerColor.withValues(alpha: 0.4),
        ),
        itemBuilder: (context, index) {
          final board = discover.boards[index];
          return _BoardRow(
            board: board,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => LeaderboardDetailScreen(
                    source: '${board['source'] ?? discover.leaderboardSource}',
                    id: '${board['id'] ?? ''}',
                    title: '${board['name'] ?? '排行榜'}',
                    coverUrl: '${board['img'] ?? ''}',
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _BoardRow extends StatelessWidget {
  const _BoardRow({required this.board, required this.onTap});

  final Map<String, dynamic> board;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final image = '${board['img'] ?? ''}';
    final name = '${board['name'] ?? '排行榜'}';
    final update = '${board['update_frequency'] ?? board['updateFrequency'] ?? ''}';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 56,
                height: 56,
                child: image.isEmpty
                    ? Container(
                        color: surfaceHighFor(context),
                        child: Icon(Icons.leaderboard_rounded, color: mutedFor(context)),
                      )
                    : Image.network(
                        image,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: surfaceHighFor(context),
                          child: Icon(Icons.leaderboard_rounded, color: mutedFor(context)),
                        ),
                      ),
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
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: textFor(context),
                    ),
                  ),
                  if (update.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(
                      update,
                      style: TextStyle(fontSize: 12, color: mutedFor(context)),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: mutedFor(context)),
          ],
        ),
      ),
    );
  }
}
