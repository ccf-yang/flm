import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../state/discover_state.dart';
import '../screens/songlist_detail_screen.dart';
import '../widgets/empty_state.dart';
import '../widgets/songlist_card.dart';
import '../widgets/source_chips.dart';

class DiscoverTab extends StatefulWidget {
  const DiscoverTab({super.key});

  @override
  State<DiscoverTab> createState() => _DiscoverTabState();
}

class _DiscoverTabState extends State<DiscoverTab> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < 600) {
      context.read<DiscoverState>().loadMoreSonglists();
    }
  }

  @override
  Widget build(BuildContext context) {
    final discover = context.watch<DiscoverState>();
    return Scaffold(
      appBar: AppBar(title: const Text('歌单')),
      body: Column(
        children: <Widget>[
          SourceChips(
            value: discover.songlistSource,
            options: kSourceOptions.where((item) => item['id'] != 'all').toList(),
            onChanged: (value) {
              discover.setSonglistSource(value);
            },
          ),
          if (discover.sortOptions.isNotEmpty)
            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: discover.sortOptions.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final sort = discover.sortOptions[index];
                  return _OptionPill(
                    label: '${sort['name'] ?? ''}',
                    active: '${sort['id']}' == discover.sortId,
                    onTap: () => discover.setSort('${sort['id']}'),
                  );
                },
              ),
            ),
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              itemCount: discover.tagOptions.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final tag = discover.tagOptions[index];
                return _OptionPill(
                  label: '${tag['name'] ?? ''}',
                  active: '${tag['id']}' == discover.tagId,
                  onTap: () => discover.setTag('${tag['id']}', '${tag['name']}'),
                );
              },
            ),
          ),
          const SizedBox(height: 6),
          Expanded(child: _buildBody(context, discover)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, DiscoverState discover) {
    if (discover.songlistLoading && discover.songlists.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (discover.songlistError != null && discover.songlists.isEmpty) {
      return EmptyState(
        title: '歌单加载失败',
        message: discover.songlistError,
        icon: Icons.cloud_off_rounded,
        action: FilledButton(
          onPressed: discover.loadSonglists,
          child: const Text('重试'),
        ),
      );
    }
    if (discover.songlists.isEmpty) {
      return const EmptyState(title: '暂时没有歌单', icon: Icons.queue_music_rounded);
    }
    return RefreshIndicator(
      onRefresh: discover.loadSonglists,
      child: CustomScrollView(
        controller: _scrollController,
        slivers: <Widget>[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 16,
                crossAxisSpacing: 12,
                childAspectRatio: 0.68,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final item = discover.songlists[index];
                  return SonglistCard(
                    item: item,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SonglistDetailScreen(
                            source: '${item['source'] ?? discover.songlistSource}',
                            id: '${item['id'] ?? ''}',
                            title: '${item['name'] ?? '歌单'}',
                            coverUrl: '${item['img'] ?? ''}',
                            description: '${item['desc'] ?? ''}',
                            playCount: '${item['play_count'] ?? ''}',
                          ),
                        ),
                      );
                    },
                  );
                },
                childCount: discover.songlists.length,
              ),
            ),
          ),
          if (discover.songlistLoadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(bottom: 24, top: 8),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _OptionPill extends StatelessWidget {
  const _OptionPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? AppColors.accent.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? AppColors.accent : mutedFor(context),
          ),
        ),
      ),
    );
  }
}
