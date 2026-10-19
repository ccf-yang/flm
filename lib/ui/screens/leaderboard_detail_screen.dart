import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../services/online_engine.dart';
import '../../state/discover_state.dart';
import '../../state/library_state.dart';
import '../../state/player_state.dart';
import '../kit.dart';
import '../widgets/active_song_tile.dart';
import '../widgets/empty_state.dart';
import '../widgets/song_actions_sheet.dart';
import '../widgets/song_tile.dart' show srcShortLabel;

class LeaderboardDetailScreen extends StatefulWidget {
  const LeaderboardDetailScreen({
    super.key,
    required this.source,
    required this.id,
    required this.title,
    this.coverUrl = '',
  });

  final String source;
  final String id;
  final String title;
  final String coverUrl;

  @override
  State<LeaderboardDetailScreen> createState() => _LeaderboardDetailScreenState();
}

class _LeaderboardDetailScreenState extends State<LeaderboardDetailScreen> {
  late final LeaderboardDetailState _state;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _state = LeaderboardDetailState(
      engine: context.read<OnlineEngine>(),
      source: widget.source,
      id: widget.id,
      title: widget.title,
      coverUrl: widget.coverUrl,
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
    flmToast(context, '已收藏到「${playlist.name}」');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: <Widget>[
          Positioned.fill(child: AuroraBackground(deep: true)),
          if (widget.coverUrl.isNotEmpty)
            Positioned.fill(
              child: Opacity(
                opacity: auroraIsDark(context) ? 0.30 : 0.16,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 46, sigmaY: 46),
                  child: Image.network(
                    widget.coverUrl,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: ListenableBuilder(
              listenable: _state,
              builder: (context, _) {
                return RefreshIndicator(
                  onRefresh: _state.load,
                  color: accentFor(context),
                  child: CustomScrollView(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    slivers: <Widget>[
                      SliverToBoxAdapter(
                        child: _Hero(
                          title: _state.title.isEmpty ? widget.title : _state.title,
                          source: _state.source,
                          coverUrl: _state.coverUrl,
                          count: _state.songs.length,
                          onPlayAll: _state.songs.isEmpty ? null : _playAll,
                          onCollect: _state.songs.isEmpty ? null : _collect,
                        ),
                      ),
                      if (_state.loading && _state.songs.isEmpty)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 48),
                            child: Center(
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2.4),
                              ),
                            ),
                          ),
                        )
                      else if (_state.error != null && _state.songs.isEmpty)
                        SliverToBoxAdapter(
                          child: EmptyState(
                            title: '榜单加载失败',
                            message: _state.error,
                            icon: CupertinoIcons.exclamationmark_shield_fill,
                            action: AuroraButton(
                              label: '重试',
                              icon: CupertinoIcons.arrow_clockwise,
                              onTap: _state.load,
                            ),
                          ),
                        )
                      else if (_state.songs.isEmpty)
                        const SliverToBoxAdapter(
                          child: EmptyState(
                            title: '这个榜单是空的',
                            icon: CupertinoIcons.chart_bar,
                          ),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(kGutter, 4, kGutter, 0),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final song = _state.songs[index];
                                return ActiveSongTile(
                                  song: song,
                                  index: index,
                                  ranked: true,
                                  onTap: () => _playSong(index),
                                  onMore: () => showSongActions(
                                    context,
                                    song,
                                    queue: _state.songs,
                                    index: index,
                                  ),
                                );
                              },
                              childCount: _state.songs.length,
                            ),
                          ),
                        ),
                      if (_state.loadingMore)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.only(top: 14, bottom: 28),
                            child: Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          ),
                        )
                      else
                        const SliverToBoxAdapter(child: SizedBox(height: 40)),
                    ],
                  ),
                );
              },
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: FlmNavBar(
              leading: IconBtn(
                icon: CupertinoIcons.chevron_left,
                onTap: () => Navigator.of(context).maybePop(),
              ),
              title: _state.title.isEmpty ? '排行榜' : _state.title,
            ),
          ),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.title,
    required this.source,
    required this.coverUrl,
    required this.count,
    required this.onPlayAll,
    required this.onCollect,
  });

  final String title;
  final String source;
  final String coverUrl;
  final int count;
  final VoidCallback? onPlayAll;
  final VoidCallback? onCollect;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Padding(
      padding: EdgeInsets.fromLTRB(kGutter, top + 62, kGutter, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Container(
                width: 122,
                height: 122,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(color: Color(0x59000000), blurRadius: 28, offset: Offset(0, 14)),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      GradientArt(
                        seed: 'board:$source:$title',
                        radius: 22,
                        decorate: true,
                        showMark: true,
                        mark: srcShortLabel(source),
                      ),
                      if (coverUrl.isNotEmpty)
                        Image.network(
                          coverUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SrcBadge(srcShortLabel(source), onDark: true),
                    const SizedBox(height: 8),
                    Text(
                      title.isEmpty ? '排行榜' : title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        height: 1.22,
                        letterSpacing: -0.4,
                        color: textFor(context),
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      '共 $count 首',
                      style: TextStyle(fontSize: 11.5, color: mutedFor(context)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              Expanded(
                child: AuroraButton(
                  label: '播放全部',
                  icon: CupertinoIcons.play_fill,
                  onTap: onPlayAll,
                  expand: true,
                ),
              ),
              const SizedBox(width: 10),
              IconBtn(
                icon: CupertinoIcons.plus_circle_fill,
                size: 44,
                onTap: onCollect,
                tooltip: '收藏榜单',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
