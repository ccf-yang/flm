import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../models/song.dart';
import '../../state/app_state.dart';
import '../../state/library_state.dart';
import '../../state/player_state.dart';
import '../../state/search_state.dart';
import '../../state/source_state.dart';
import '../kit.dart';
import '../screens/custom_sources_screen.dart';
import '../screens/songlist_detail_screen.dart';
import '../widgets/empty_state.dart';
import '../widgets/song_actions_sheet.dart';
import '../widgets/song_tile.dart';
import '../widgets/songlist_card.dart';
import '../widgets/source_chips.dart';
import '../root_shell.dart' show kRootChromeSpace;

class SearchTab extends StatefulWidget {
  const SearchTab({super.key});

  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<SearchState>().loadHotSearch().catchError((_) {});
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < 500) {
      context.read<SearchState>().loadMore();
    }
  }

  Future<void> _submit(String text) async {
    FocusScope.of(context).unfocus();
    await context.read<SearchState>().search(text);
  }

  void _useKeyword(String keyword) {
    _controller.text = keyword;
    _controller.selection = TextSelection.collapsed(offset: keyword.length);
    _submit(keyword);
  }

  void _playSong(Song song) {
    final library = context.read<LibraryState>();
    final player = context.read<PlayerController>();
    final index = library.ensureInDefault(song);
    player.playSong(song, queue: library.defaultPlaylist.songs, index: index);
  }

  @override
  Widget build(BuildContext context) {
    final search = context.watch<SearchState>();
    final appState = context.watch<AppState>();
    final top = MediaQuery.paddingOf(context).top + 10;

    return Scaffold(
      body: search.query.isEmpty
          ? _buildHero(context, search, appState, top)
          : _buildResults(context, search, top),
    );
  }

  // ---------- Hero (screen-search) ----------

  Widget _buildHero(
    BuildContext context,
    SearchState search,
    AppState appState,
    double top,
  ) {
    final sourceState = context.watch<SourceState>();
    final history = appState.settings.searchHistory;

    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: EdgeInsets.fromLTRB(kGutter, top, kGutter, 0),
          sliver: SliverToBoxAdapter(
            child: ScreenHead(
              overline: 'Search / 01',
              title: '听点什么',
              subtitle: '找到下一首，让你单曲循环的歌。',
              trailing: Pressable(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const CustomSourcesScreen(),
                    ),
                  );
                },
                child: StatusChip(
                  ok: sourceState.hasActiveSource,
                  label: sourceState.hasActiveSource ? '音源已连接' : '内置源模式',
                ),
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(kGutter, 16, kGutter, 0),
          sliver: SliverToBoxAdapter(
            child: SearchField(
              controller: _controller,
              hint: '搜索歌曲、歌手、歌单',
              trailing: _controller.text.isEmpty ? const EnterKbd() : null,
              onChanged: (value) {
                setState(() {});
                search.updateTips(value);
              },
              onSubmitted: _submit,
              onClear: () {
                _controller.clear();
                search.clear();
              },
            ),
          ),
        ),
        if (search.tips.isNotEmpty && _controller.text.trim().isNotEmpty)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(kGutter, 10, kGutter, 0),
            sliver: SliverToBoxAdapter(child: _suggestCard(context, search)),
          ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(kGutter, 14, kGutter, 0),
          sliver: SliverToBoxAdapter(
            child: AuroraSegmented(
              items: const <String>['歌曲', '歌单'],
              activeIndex: search.type == SearchType.music ? 0 : 1,
              onChanged: (index) =>
                  search.setType(index == 0 ? SearchType.music : SearchType.songlist),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.only(top: 12),
          sliver: SliverToBoxAdapter(
            child: SourceChips(
              value: search.source,
              onChanged: (value) async {
                await search.setSource(value);
                await search.loadHotSearch();
              },
            ),
          ),
        ),
        if (search.hotSearch.isNotEmpty) ...<Widget>[
          SliverToBoxAdapter(
            child: SectionHead(
              title: '热门搜索',
              actionLabel: '换一批',
              actionIcon: CupertinoIcons.arrow_clockwise,
              onAction: () => search.loadHotSearch(),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: kGutter),
            sliver: SliverToBoxAdapter(
              child: _HotGrid(
                words: search.hotSearch.take(12).toList(),
                onPick: _useKeyword,
              ),
            ),
          ),
        ],
        if (history.isNotEmpty) ...<Widget>[
          SliverToBoxAdapter(
            child: SectionHead(
              title: '搜索历史',
              actionLabel: '清空',
              onAction: appState.clearSearchHistory,
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(kGutter, 0, kGutter, 0),
            sliver: SliverToBoxAdapter(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: history.map((word) {
                  return _KeywordChip(
                    label: word,
                    onTap: () => _useKeyword(word),
                    onLongPress: () => appState.removeSearchHistory(word),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
        if (search.hotSearch.isEmpty && history.isEmpty && search.loading == false && search.error != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 40),
              child: EmptyState(
                title: '搜索暂不可用',
                message: search.error,
                icon: CupertinoIcons.exclamationmark_shield_fill,
                action: AuroraButton(
                  label: '重试',
                  onTap: () => search.loadHotSearch(),
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(child: SizedBox(height: kRootChromeSpace)),
      ],
    );
  }

  Widget _suggestCard(BuildContext context, SearchState search) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: surfaceFor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: lineColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 7),
            child: Overline('搜索建议'.toUpperCase()),
          ),
          ...search.tips.take(8).map((tip) {
            return Pressable(
              onTap: () => _useKeyword(tip),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  children: <Widget>[
                    Icon(CupertinoIcons.search, size: 13, color: faintFor(context)),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        tip,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: mutedFor(context)),
                      ),
                    ),
                    Text(
                      '歌曲',
                      style: TextStyle(fontSize: 9, color: faintFor(context)),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // ---------- Results (screen-results) ----------

  Widget _buildResults(BuildContext context, SearchState search, double top) {
    final musicCount = search.musicResults.length;
    final listCount = search.songlistResults.length;
    final platforms = <String>{
      ...search.musicResults.map((song) => song.source),
      ...search.songlistResults.map((item) => '${item['source'] ?? ''}'),
    }.where((value) => value.isNotEmpty).length;

    Widget body;
    if (search.loading) {
      body = Padding(
        padding: EdgeInsets.only(top: MediaQuery.sizeOf(context).height * 0.28),
        child: const Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    } else if (search.error != null) {
      body = EmptyState(
        title: '加载失败',
        message: search.error,
        icon: CupertinoIcons.exclamationmark_shield_fill,
        action: AuroraButton(
          label: '重试',
          onTap: () => search.search(search.query),
        ),
      );
    } else if (search.type == SearchType.music) {
      body = musicCount == 0
          ? EmptyState(
              title: '没有找到歌曲',
              message: '换个关键词，或试试其他平台',
              icon: CupertinoIcons.music_note,
            )
          : ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 200),
              itemCount: musicCount + (search.hasMore || search.loadingMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= musicCount) {
                  return const Padding(
                    padding: EdgeInsets.all(18),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                final song = search.musicResults[index];
                return SongTile(
                  song: song,
                  index: index,
                  ranked: true,
                  onTap: () => _playSong(song),
                  onMore: () => showSongActions(context, song),
                );
              },
            );
    } else {
      body = listCount == 0
          ? EmptyState(
              title: '没有找到歌单',
              message: '换个关键词，或试试其他平台',
              icon: CupertinoIcons.music_albums,
            )
          : GridView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.only(top: 4, bottom: 200),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 14,
                crossAxisSpacing: 12,
                childAspectRatio: 0.68,
              ),
              itemCount: listCount + (search.hasMore || search.loadingMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= listCount) {
                  return const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                final item = search.songlistResults[index];
                return SonglistCard(
                  item: item,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SonglistDetailScreen(
                          source: '${item['source'] ?? ''}',
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
            );
    }

    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(kGutter - 6, top, kGutter - 6, 0),
            child: Row(
              children: <Widget>[
                IconBtn(
                  icon: CupertinoIcons.chevron_left,
                  size: 34,
                  onTap: () {
                    _controller.clear();
                    search.clear();
                  },
                  tooltip: '返回',
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Overline('Search results'.toUpperCase()),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(kGutter, 16, kGutter, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Overline('Found for'.toUpperCase()),
                const SizedBox(height: 5),
                Text(
                  '“${search.query}”',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1.2,
                    color: textFor(context),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '$musicCount 首歌曲 · $listCount 个歌单'
                  '${platforms > 0 ? ' · 来自 $platforms 个平台' : ''}',
                  style: TextStyle(fontSize: 11, color: mutedFor(context)),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(kGutter, 15, kGutter, 0),
            child: Column(
              children: <Widget>[
                SearchField(
                  controller: _controller,
                  hint: '继续搜索',
                  compact: true,
                  onChanged: (value) => search.updateTips(value),
                  onSubmitted: _submit,
                  onClear: () {
                    _controller.clear();
                    search.clear();
                  },
                ),
                const SizedBox(height: 9),
                AuroraSegmented(
                  items: <String>['歌曲 $musicCount', '歌单 $listCount'],
                  activeIndex: search.type == SearchType.music ? 0 : 1,
                  onChanged: (index) =>
                      search.setType(index == 0 ? SearchType.music : SearchType.songlist),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: SourceChips(
              value: search.source,
              onChanged: (value) async {
                await search.setSource(value);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(kGutter, 15, kGutter, 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  '按相关度排序',
                  style: TextStyle(fontSize: 9.5, color: faintFor(context)),
                ),
                Text(
                  '点击歌曲直接播放',
                  style: TextStyle(fontSize: 9.5, color: faintFor(context)),
                ),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _HotGrid extends StatelessWidget {
  const _HotGrid({required this.words, required this.onPick});

  final List<String> words;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 108 / 42,
      ),
      itemCount: words.length,
      itemBuilder: (context, index) {
        final word = words[index];
        return Pressable(
          onTap: () => onPick(word),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: surfaceFor(context),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: lineColor(context)),
            ),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 15,
                  child: Text(
                    (index + 1).toString().padLeft(2, '0'),
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: index < 3 ? accentFor(context) : faintFor(context),
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    word,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: textFor(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _KeywordChip extends StatelessWidget {
  const _KeywordChip({
    required this.label,
    required this.onTap,
    this.onLongPress,
  });

  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: surface2For(context),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 11.5, color: mutedFor(context)),
        ),
      ),
    );
  }
}
