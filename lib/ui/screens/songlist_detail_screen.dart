import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../services/online_engine.dart';
import '../../state/discover_state.dart';
import '../../state/library_state.dart';
import '../../state/player_state.dart';
import '../widgets/empty_state.dart';
import '../widgets/song_actions_sheet.dart';
import '../widgets/active_song_tile.dart';

class SonglistDetailScreen extends StatefulWidget {
  const SonglistDetailScreen({
    super.key,
    required this.source,
    required this.id,
    required this.title,
    this.coverUrl = '',
    this.description = '',
    this.playCount = '',
  });

  final String source;
  final String id;
  final String title;
  final String coverUrl;
  final String description;
  final String playCount;

  @override
  State<SonglistDetailScreen> createState() => _SonglistDetailScreenState();
}

class _SonglistDetailScreenState extends State<SonglistDetailScreen> {
  late final SonglistDetailState _state;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _state = SonglistDetailState(
      engine: context.read<OnlineEngine>(),
      source: widget.source,
      id: widget.id,
      title: widget.title,
      coverUrl: widget.coverUrl,
      description: widget.description,
      playCount: widget.playCount,
    );
    _state.load();
    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;
      if (_scrollController.position.extentAfter < 500) {
        _state.loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _state.dispose();
    super.dispose();
  }

  void _playSong(int index) {
    final song = _state.songs[index];
    context.read<PlayerController>().playSong(
          song,
          queue: _state.songs,
          index: index,
        );
  }

  void _playAll() {
    if (_state.songs.isEmpty) return;
    context.read<PlayerController>().playSong(
          _state.songs.first,
          queue: _state.songs,
          index: 0,
        );
  }

  void _collect() {
    if (_state.songs.isEmpty) return;
    final library = context.read<LibraryState>();
    final playlist = library.createPlaylist(_state.title);
    library.addSongs(playlist.id, _state.songs);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已收藏到「${playlist.name}」')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _state.title.isEmpty ? '歌单' : _state.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '收藏歌单',
            onPressed: _state.songs.isEmpty ? null : _collect,
            icon: const Icon(Icons.playlist_add_rounded),
          ),
          IconButton(
            tooltip: '播放全部',
            onPressed: _state.songs.isEmpty ? null : _playAll,
            icon: const Icon(Icons.play_circle_fill_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListenableBuilder(
        listenable: _state,
        builder: (context, _) {
          if (_state.loading && _state.songs.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_state.error != null && _state.songs.isEmpty) {
            return EmptyState(
              title: '歌单加载失败',
              message: _state.error,
              icon: Icons.cloud_off_rounded,
              action: FilledButton(
                onPressed: _state.load,
                child: const Text('重试'),
              ),
            );
          }
          if (_state.songs.isEmpty) {
            return const EmptyState(title: '这个歌单是空的', icon: Icons.queue_music_rounded);
          }
          return RefreshIndicator(
            onRefresh: _state.load,
            child: ListView.builder(
              controller: _scrollController,
              itemCount: _state.songs.length + 1 + (_state.loadingMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _Header(state: _state, onPlayAll: _playAll, onCollect: _collect);
                }
                final songIndex = index - 1;
                if (songIndex >= _state.songs.length) {
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
                final song = _state.songs[songIndex];
                return ActiveSongTile(
                  song: song,
                  index: songIndex,
                  onTap: () => _playSong(songIndex),
                  onMore: () => showSongActions(
                    context,
                    song,
                    queue: _state.songs,
                    index: songIndex,
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.state,
    required this.onPlayAll,
    required this.onCollect,
  });

  final SonglistDetailState state;
  final VoidCallback onPlayAll;
  final VoidCallback onCollect;

  @override
  Widget build(BuildContext context) {
    final playCount = state.playCount.isNotEmpty
        ? state.playCount
        : formatPlayCount(state.info['play_count']);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _Cover(url: state.coverUrl),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      state.title.isEmpty ? '${state.info['name'] ?? '歌单'}' : state.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                        color: textFor(context),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: <Widget>[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.accent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            state.source.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppColors.accent,
                            ),
                          ),
                        ),
                        if (playCount.isNotEmpty) ...<Widget>[
                          const SizedBox(width: 8),
                          Icon(Icons.play_arrow_rounded, size: 14, color: mutedFor(context)),
                          Text(playCount, style: TextStyle(fontSize: 12, color: mutedFor(context))),
                        ],
                      ],
                    ),
                    if (state.description.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        state.description,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, height: 1.35, color: mutedFor(context)),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: onPlayAll,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text('播放全部（${state.songs.length}）'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: onCollect,
                icon: const Icon(Icons.playlist_add_rounded, size: 18),
                label: const Text('收藏'),
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 108,
        height: 108,
        child: url.isEmpty
            ? Container(
                color: surfaceHighFor(context),
                child: Icon(Icons.queue_music_rounded, size: 38, color: mutedFor(context)),
              )
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: surfaceHighFor(context),
                  child: Icon(Icons.queue_music_rounded, size: 38, color: mutedFor(context)),
                ),
              ),
      ),
    );
  }
}
