import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../models/song.dart';
import '../../state/app_state.dart';
import '../../state/library_state.dart';
import '../../state/player_state.dart';
import '../../state/search_state.dart';
import '../screens/songlist_detail_screen.dart';
import '../widgets/empty_state.dart';
import '../widgets/song_actions_sheet.dart';
import '../widgets/song_tile.dart';
import '../widgets/source_chips.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('搜索'),
        actions: <Widget>[
          if (search.query.isNotEmpty)
            TextButton(
              onPressed: () {
                _controller.clear();
                search.clear();
              },
              child: const Text('清空'),
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onChanged: (value) {
                setState(() {});
                search.updateTips(value);
              },
              onSubmitted: (value) {
                _submit(value);
              },
              style: TextStyle(fontSize: 15, color: textFor(context)),
              decoration: InputDecoration(
                hintText: '搜索歌曲、歌手、歌单',
                hintStyle: TextStyle(color: mutedFor(context), fontSize: 14),
                prefixIcon: Icon(Icons.search_rounded, color: mutedFor(context)),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.close_rounded, color: mutedFor(context), size: 18),
                        onPressed: () {
                          _controller.clear();
                          search.clear();
                        },
                      )
                    : null,
                filled: true,
                fillColor: surfaceHighFor(context),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: CupertinoSlidingSegmentedControl<SearchType>(
              groupValue: search.type,
              onValueChanged: (value) {
                if (value == null) return;
                search.setType(value);
              },
              children: const <SearchType, Widget>{
                SearchType.music: Padding(
                  padding: EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                  child: Text('歌曲'),
                ),
                SearchType.songlist: Padding(
                  padding: EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                  child: Text('歌单'),
                ),
              },
            ),
          ),
          const SizedBox(height: 4),
          SourceChips(
            value: search.source,
            onChanged: (value) async {
              await search.setSource(value);
              await search.loadHotSearch();
            },
          ),
          Expanded(
            child: search.query.isEmpty
                ? _buildDiscover(context, search, appState)
                : _buildResults(context, search),
          ),
        ],
      ),
    );
  }

  Widget _buildDiscover(BuildContext context, SearchState search, AppState appState) {
    final history = appState.settings.searchHistory;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        if (search.tips.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Container(
              decoration: BoxDecoration(
                color: surfaceFor(context),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: search.tips.take(8).map((tip) {
                  return ListTile(
                    dense: true,
                    leading: Icon(Icons.north_west_rounded, size: 18, color: mutedFor(context)),
                    title: Text(tip),
                    onTap: () => _useKeyword(tip),
                  );
                }).toList(),
              ),
            ),
          ),
        if (search.hotSearch.isNotEmpty)
          SectionHeader(
            title: '热门搜索',
            trailing: TextButton(
              onPressed: () => search.loadHotSearch(),
              child: const Text('换一批'),
            ),
          ),
        if (search.hotSearch.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: search.hotSearch.take(20).map((word) {
                return _KeywordChip(
                  label: word,
                  onTap: () => _useKeyword(word),
                );
              }).toList(),
            ),
          ),
        if (history.isNotEmpty) ...<Widget>[
          SectionHeader(
            title: '搜索历史',
            trailing: TextButton(
              onPressed: appState.clearSearchHistory,
              child: const Text('清空'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
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
        ],
        if (search.hotSearch.isEmpty && history.isEmpty && search.tips.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 60),
            child: EmptyState(
              title: '搜我所想',
              message: '输入关键词，或先到「设置 → 自定义源」启用音源',
              icon: Icons.search_rounded,
            ),
          ),
      ],
    );
  }

  Widget _buildResults(BuildContext context, SearchState search) {
    if (search.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (search.error != null) {
      return EmptyState(
        title: '加载失败',
        message: search.error,
        icon: Icons.error_outline_rounded,
        action: FilledButton(
          onPressed: () => search.search(search.query),
          child: const Text('重试'),
        ),
      );
    }
    if (search.type == SearchType.music) {
      if (search.musicResults.isEmpty) {
        return const EmptyState(title: '没有找到歌曲', icon: Icons.music_off_rounded);
      }
      return ListView.builder(
        controller: _scrollController,
        itemCount: search.musicResults.length + (search.hasMore || search.loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= search.musicResults.length) {
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
            showCover: true,
            onTap: () => _playSong(song),
            onMore: () => showSongActions(context, song),
          );
        },
      );
    }

    if (search.songlistResults.isEmpty) {
      return const EmptyState(title: '没有找到歌单', icon: Icons.queue_music_rounded);
    }
    return ListView.separated(
      controller: _scrollController,
      itemCount: search.songlistResults.length + (search.hasMore || search.loadingMore ? 1 : 0),
      separatorBuilder: (_, __) => Divider(
        height: 1,
        indent: 86,
        color: Theme.of(context).dividerColor.withValues(alpha: 0.4),
      ),
      itemBuilder: (context, index) {
        if (index >= search.songlistResults.length) {
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
        final item = search.songlistResults[index];
        return _SonglistRow(
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: surfaceHighFor(context),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 13, color: textFor(context)),
        ),
      ),
    );
  }
}

class _SonglistRow extends StatelessWidget {
  const _SonglistRow({required this.item, required this.onTap});

  final Map<String, dynamic> item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final image = '${item['img'] ?? ''}';
    final name = '${item['name'] ?? '未命名歌单'}';
    final author = '${item['author'] ?? ''}';
    final count = '${item['play_count'] ?? ''}';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 58,
                height: 58,
                child: image.isEmpty
                    ? Container(
                        color: surfaceHighFor(context),
                        child: Icon(Icons.queue_music_rounded, color: mutedFor(context)),
                      )
                    : Image.network(
                        image,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: surfaceHighFor(context),
                          child: Icon(Icons.queue_music_rounded, color: mutedFor(context)),
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
                  const SizedBox(height: 3),
                  Text(
                    <String>[
                      if (author.isNotEmpty) author,
                      if (count.isNotEmpty) count,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: mutedFor(context)),
                  ),
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
