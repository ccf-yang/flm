import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../state/app_state.dart';
import '../../state/discover_state.dart';
import '../kit.dart';
import '../root_shell.dart' show kRootChromeSpace;
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

  void _openSonglist(BuildContext context, Map<String, dynamic> item, DiscoverState discover) {
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
  }

  @override
  Widget build(BuildContext context) {
    final discover = context.watch<DiscoverState>();
    final settings = context.watch<AppState>().settings;
    final top = MediaQuery.paddingOf(context).top + 10;

    return Scaffold(
      body: CustomScrollView(
        controller: _scrollController,
        slivers: <Widget>[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(kGutter, top, kGutter, 16),
            sliver: SliverToBoxAdapter(
              child: ScreenHead(
                overline: 'Discover / 02',
                title: '歌单广场',
                subtitle: '从一个封面，进入一整晚的心情。',
                trailing: IconBtn(
                  icon: CupertinoIcons.arrow_clockwise,
                  tooltip: '刷新',
                  onTap: discover.loadSonglists,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SourceChips(
              value: discover.songlistSource,
              settings: settings,
              allowAggregate: false,
              onChanged: (value) {
                discover.setSonglistSource(value);
              },
            ),
          ),
          if (discover.sortOptions.isNotEmpty)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 36,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: kGutter),
                  itemCount: discover.sortOptions.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final sort = discover.sortOptions[index];
                    return OptionPill(
                      label: '${sort['name'] ?? ''}',
                      active: '${sort['id']}' == discover.sortId,
                      onTap: () => discover.setSort('${sort['id']}'),
                    );
                  },
                ),
              ),
            ),
          if (discover.tagOptions.isNotEmpty)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 36,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: kGutter),
                  itemCount: discover.tagOptions.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final tag = discover.tagOptions[index];
                    return OptionPill(
                      label: '${tag['name'] ?? ''}',
                      active: '${tag['id']}' == discover.tagId,
                      onTap: () => discover.setTag('${tag['id']}', '${tag['name']}'),
                    );
                  },
                ),
              ),
            ),
          if (discover.songlistLoading && discover.songlists.isEmpty)
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
          else if (discover.songlistError != null && discover.songlists.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 40),
                child: EmptyState(
                  title: '歌单加载失败',
                  message: discover.songlistError,
                  icon: CupertinoIcons.exclamationmark_shield_fill,
                  action: AuroraButton(
                    label: '重试',
                    onTap: discover.loadSonglists,
                  ),
                ),
              ),
            )
          else if (discover.songlists.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: 40),
                child: EmptyState(
                  title: '暂时没有歌单',
                  message: '换个平台或稍后重试',
                  icon: CupertinoIcons.music_albums,
                ),
              ),
            )
          else ...<Widget>[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(kGutter, 16, kGutter, 0),
              sliver: SliverToBoxAdapter(
                child: _FeaturedCard(
                  item: discover.songlists.first,
                  source: discover.songlistSource,
                  onTap: () => _openSonglist(context, discover.songlists.first, discover),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SectionHead(
                title: '继续探索',
                note: '${discover.songlists.length - 1} 个歌单',
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(kGutter, 2, kGutter, 0),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.68,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = discover.songlists[index + 1];
                    return SonglistCard(
                      item: item,
                      onTap: () => _openSonglist(context, item, discover),
                    );
                  },
                  childCount: discover.songlists.length - 1,
                ),
              ),
            ),
            if (discover.songlistLoadingMore)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 24, top: 14),
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
          const SliverToBoxAdapter(child: SizedBox(height: kRootChromeSpace)),
        ],
      ),
    );
  }
}

class _FeaturedCard extends StatelessWidget {
  const _FeaturedCard({
    required this.item,
    required this.source,
    required this.onTap,
  });

  final Map<String, dynamic> item;
  final String source;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final image = '${item['img'] ?? ''}';
    final name = '${item['name'] ?? '歌单'}';
    final desc = '${item['desc'] ?? ''}';
    final count = '${item['play_count'] ?? ''}';

    return Pressable(
      onTap: onTap,
      child: Container(
        height: 214,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(25),
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
              seed: '$source:${item['id'] ?? ''}:$name',
              radius: 0,
              decorate: true,
            ),
            if (image.isNotEmpty)
              Positioned.fill(
                child: Image.network(
                  image,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return const SizedBox.shrink();
                  },
                ),
              ),
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: <Color>[
                      Color(0xF0040709),
                      Color(0x59040709),
                      Color(0x00040709),
                    ],
                    stops: <double>[0, 0.5, 0.8],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 18,
              right: 80,
              bottom: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
                    ),
                    child: const Text(
                      '编辑精选',
                      style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 25,
                      height: 1.08,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1.1,
                      color: Colors.white,
                    ),
                  ),
                  if (desc.isNotEmpty || count.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 5),
                    Text(
                      <String>[
                        if (desc.isNotEmpty) desc,
                        if (count.isNotEmpty) count,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: Colors.white.withValues(alpha: 0.64),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Positioned(
              right: 17,
              bottom: 17,
              child: Pressable(
                onTap: onTap,
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accentFor(context),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x40000000),
                        blurRadius: 26,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Icon(
                    CupertinoIcons.play_fill,
                    size: 20,
                    color: accentInkFor(context),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
