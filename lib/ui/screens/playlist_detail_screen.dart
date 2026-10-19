import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../state/library_state.dart';
import '../../state/player_state.dart';
import '../kit.dart';
import '../widgets/active_song_tile.dart';
import '../widgets/empty_state.dart';
import '../widgets/song_actions_sheet.dart';

class PlaylistDetailScreen extends StatefulWidget {
  const PlaylistDetailScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selected = <String>{};
  bool _selecting = false;
  bool _showSearch = false;
  bool _reorderMode = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryState>();
    final playlist = library.byId(widget.playlistId);
    if (playlist == null) {
      return Scaffold(
        body: Stack(
          children: <Widget>[
            Positioned.fill(child: AuroraBackground(deep: true)),
            const Positioned.fill(
              child: EmptyState(title: '列表不存在', icon: CupertinoIcons.music_note_list),
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
                title: '列表',
              ),
            ),
          ],
        ),
      );
    }

    final songs = _showSearch && _searchController.text.trim().isNotEmpty
        ? library.searchInPlaylist(playlist.id, _searchController.text)
        : playlist.songs;

    return Scaffold(
      body: Stack(
        children: <Widget>[
          Positioned.fill(child: AuroraBackground(deep: true)),
          SafeArea(
            bottom: false,
            child: Column(
              children: <Widget>[
                FlmNavBar(
                  leading: IconBtn(
                    icon: _selecting ? CupertinoIcons.xmark_circle_fill : CupertinoIcons.chevron_left,
                    onTap: _selecting ? _exitSelection : () => Navigator.of(context).maybePop(),
                  ),
                  title: _selecting ? '已选择 ${_selected.length} 首' : playlist.name,
                  trailing: _buildTrailing(playlist, songs),
                ),
                if (_showSearch && !_selecting)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(kGutter, 2, kGutter, 8),
                      child: SearchField(
                        controller: _searchController,
                        hint: '在列表中搜索',
                        compact: true,
                        autofocus: true,
                        onChanged: (_) => setState(() {}),
                        onClear: () {
                          _searchController.clear();
                          setState(() {});
                        },
                      ),
                    ),
                Expanded(
                  child: _reorderMode
                      ? _buildReorderList(playlist, library)
                      : _buildList(playlist, songs, library),
                ),
              ],
            ),
          ),
          if (_selecting)
            Positioned(
              left: kGutter,
              right: kGutter,
              bottom: MediaQuery.paddingOf(context).bottom + 16,
              child: _SelectionBar(
                count: _selected.length,
                total: songs.length,
                onSelectAll: () {
                  setState(() {
                    if (_selected.length == songs.length) {
                      _selected.clear();
                    } else {
                      _selected
                        ..clear()
                        ..addAll(songs.map((song) => song.id));
                    }
                  });
                },
                onAdd: _selected.isEmpty
                    ? null
                    : () {
                        showSongsToPlaylist(
                          context,
                          songs.where((song) => _selected.contains(song.id)).toList(),
                        );
                        _exitSelection();
                      },
                onDelete: _selected.isEmpty
                    ? null
                    : () => _deleteSelected(playlist, songs),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildTrailing(Playlist playlist, List<Song> songs) {
    if (_selecting) return const <Widget>[];
    if (_reorderMode) {
      return <Widget>[
        IconBtn(
          icon: CupertinoIcons.check_mark,
          tooltip: '完成',
          onTap: () => setState(() => _reorderMode = false),
        ),
      ];
    }
    return <Widget>[
      IconBtn(
        icon: _showSearch ? CupertinoIcons.xmark_circle_fill : CupertinoIcons.search,
        tooltip: '搜索',
        onTap: () {
          setState(() => _showSearch = !_showSearch);
          if (!_showSearch) _searchController.clear();
        },
      ),
      const SizedBox(width: 6),
      IconBtn(
        icon: CupertinoIcons.ellipsis,
        tooltip: '更多',
        onTap: () => _showMoreMenu(playlist),
      ),
    ];
  }

  Widget _buildList(
    Playlist playlist,
    List<Song> songs,
    LibraryState library,
  ) {
    if (playlist.songs.isEmpty) {
      return EmptyState(
        title: '这个列表还是空的',
        message: playlist.id == 'local'
            ? '点击下方按钮从设备导入本地音乐'
            : '去搜索歌曲，然后添加到这个列表',
        icon: _playlistIcon(playlist),
        action: playlist.id == 'local'
            ? AuroraButton(
                label: '导入本地音乐',
                icon: CupertinoIcons.folder,
                onTap: () => _importLocal(),
              )
            : null,
      );
    }
    if (songs.isEmpty) {
      return const EmptyState(title: '没有匹配的歌曲', icon: CupertinoIcons.search);
    }
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: _PlaylistHero(
            playlist: playlist,
            icon: _playlistIcon(playlist),
            onPlayAll: () => _playAll(playlist),
            onShuffle: () => _shuffle(playlist),
            onImportLocal: playlist.id == 'local' ? () => _importLocal() : null,
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(kGutter, 4, kGutter, _selecting ? 96 : 28),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final songIndex = index;
                final song = songs[songIndex];
                return ActiveSongTile(
                  song: song,
                  index: songIndex,
                  ranked: true,
                  selected: _selected.contains(song.id),
                  selectionMode: _selecting,
                  onTap: () {
                    if (_selecting) {
                      _toggleSelect(song);
                    } else {
                      context.read<PlayerController>().playSong(
                            song,
                            queue: songs,
                            index: songIndex,
                          );
                    }
                  },
                  onLongPress: () {
                    if (_selecting) {
                      _toggleSelect(song);
                    } else {
                      setState(() {
                        _selecting = true;
                        _selected.add(song.id);
                      });
                    }
                  },
                  onMore: () => showSongActions(context, song, queue: songs, index: songIndex),
                );
              },
              childCount: songs.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReorderList(Playlist playlist, LibraryState library) {
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: EdgeInsets.fromLTRB(kGutter, 6, kGutter, 28),
      itemCount: playlist.songs.length,
      // Flutter 3.41 deprecates onReorder in favour of onReorderItem; keeping
      // onReorder keeps compatibility with older Flutter 3.2x SDKs.
      // ignore: deprecated_member_use
      onReorder: (oldIndex, newIndex) {
        library.reorderSong(playlist.id, oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        final song = playlist.songs[index];
        return KeyedSubtree(
          key: ValueKey<String>('${song.source}:${song.id}'),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: ActiveSongTile(
              song: song,
              index: index,
              ranked: true,
              trailing: ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                  child: Icon(CupertinoIcons.bars, color: mutedFor(context)),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  IconData _playlistIcon(Playlist playlist) {
    switch (playlist.id) {
      case 'love':
        return CupertinoIcons.heart_fill;
      case 'local':
        return CupertinoIcons.folder;
      case 'default':
        return CupertinoIcons.music_note_list;
      default:
        return CupertinoIcons.music_albums;
    }
  }

  void _toggleSelect(Song song) {
    setState(() {
      if (!_selected.add(song.id)) {
        _selected.remove(song.id);
      }
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _playAll(Playlist playlist) {
    if (playlist.songs.isEmpty) return;
    final player = context.read<PlayerController>();
    player.playSong(playlist.songs.first, queue: playlist.songs, index: 0);
  }

  Future<void> _shuffle(Playlist playlist) async {
    if (playlist.songs.isEmpty) return;
    final player = context.read<PlayerController>();
    await player.playSong(playlist.songs.first, queue: playlist.songs, index: 0);
    player.shuffleQueue();
  }

  Future<void> _importLocal() async {
    try {
      final count = await context.read<LibraryState>().importLocalMusic();
      if (!mounted) return;
      flmToast(context, count == 0 ? '没有导入任何歌曲' : '已导入 $count 首本地歌曲');
    } catch (error) {
      if (!mounted) return;
      flmToast(context, '导入失败: $error');
    }
  }

  Future<void> _deleteSelected(Playlist playlist, List<Song> songs) async {
    final songsToDelete = songs.where((song) => _selected.contains(song.id)).toList();
    if (songsToDelete.isEmpty) return;
    final confirmed = await flmConfirmDialog(
      context,
      title: '删除歌曲',
      message: '确定要从「${playlist.name}」中删除所选的 ${songsToDelete.length} 首歌曲吗？',
      confirmLabel: '删除',
      danger: true,
    );
    if (!confirmed || !mounted) return;
    context.read<LibraryState>().removeSongs(
          playlist.id,
          songsToDelete.map((song) => song.id).toSet(),
        );
    _exitSelection();
  }

  Future<void> _showMoreMenu(Playlist playlist) async {
    await showFlmSheet<void>(
      context,
      title: playlist.name,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (!playlist.isBuiltIn) ...<Widget>[
            SheetAction(
              icon: CupertinoIcons.doc,
              label: '重命名',
              onTap: () {
                Navigator.pop(context);
                _rename(playlist);
              },
            ),
            SheetAction(
              icon: CupertinoIcons.trash,
              label: '删除列表',
              danger: true,
              onTap: () {
                Navigator.pop(context);
                _deletePlaylist(playlist);
              },
            ),
          ],
          SheetAction(
            icon: CupertinoIcons.list_number,
            label: '按歌名排序（升序）',
            onTap: () {
              context.read<LibraryState>().sortPlaylist(playlist.id, 'name', true);
              Navigator.pop(context);
            },
          ),
          SheetAction(
            icon: CupertinoIcons.list_number,
            label: '按歌名排序（降序）',
            onTap: () {
              context.read<LibraryState>().sortPlaylist(playlist.id, 'name', false);
              Navigator.pop(context);
            },
          ),
          SheetAction(
            icon: CupertinoIcons.person,
            label: '按艺术家排序',
            onTap: () {
              context.read<LibraryState>().sortPlaylist(playlist.id, 'singer', true);
              Navigator.pop(context);
            },
          ),
          SheetAction(
            icon: CupertinoIcons.music_albums,
            label: '按专辑排序',
            onTap: () {
              context.read<LibraryState>().sortPlaylist(playlist.id, 'album', true);
              Navigator.pop(context);
            },
          ),
          SheetAction(
            icon: CupertinoIcons.arrow_down,
            label: '手动调整顺序',
            onTap: () {
              Navigator.pop(context);
              setState(() => _reorderMode = true);
            },
          ),
          SheetAction(
            icon: CupertinoIcons.xmark_circle_fill,
            label: '清空列表',
            danger: true,
            onTap: () {
              Navigator.pop(context);
              _clearPlaylist(playlist);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _rename(Playlist playlist) async {
    final name = await flmInputDialog(
      context,
      title: '重命名列表',
      placeholder: '列表名称',
      initialValue: playlist.name,
      confirmLabel: '保存',
    );
    if (name == null || name.isEmpty || !mounted) return;
    context.read<LibraryState>().renamePlaylist(playlist.id, name);
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final confirmed = await flmConfirmDialog(
      context,
      title: '删除列表',
      message: '确定要删除「${playlist.name}」及其中的所有歌曲吗？',
      confirmLabel: '删除',
      danger: true,
    );
    if (!confirmed) return;
    if (!mounted) return;
    context.read<LibraryState>().deletePlaylist(playlist.id);
    Navigator.of(context).pop();
  }

  Future<void> _clearPlaylist(Playlist playlist) async {
    final confirmed = await flmConfirmDialog(
      context,
      title: '清空列表',
      message: '确定要清空「${playlist.name}」中的所有歌曲吗？',
      confirmLabel: '清空',
      danger: true,
    );
    if (!confirmed) return;
    if (!mounted) return;
    context.read<LibraryState>().removeSongs(
          playlist.id,
          playlist.songs.map((song) => song.id).toSet(),
        );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.total,
    required this.onSelectAll,
    required this.onAdd,
    required this.onDelete,
  });

  final int count;
  final int total;
  final VoidCallback onSelectAll;
  final VoidCallback? onAdd;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final allSelected = count > 0 && count == total;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: surfaceFor(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: lineStrongColor(context)),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x59000000), blurRadius: 30, offset: Offset(0, 10)),
        ],
      ),
      child: Row(
        children: <Widget>[
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '已选 $count',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: textFor(context),
                ),
              ),
              Text(
                '共 $total 首',
                style: TextStyle(fontSize: 10.5, color: mutedFor(context)),
              ),
            ],
          ),
          const Spacer(),
          TextButton(
            onPressed: onSelectAll,
            child: Text(
              allSelected ? '取消全选' : '全选',
              style: TextStyle(color: accentFor(context), fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 4),
          IconBtn(
            icon: CupertinoIcons.plus_circle_fill,
            size: 38,
            onTap: onAdd,
            tooltip: '添加到列表',
          ),
          const SizedBox(width: 8),
          IconBtn(
            icon: CupertinoIcons.trash,
            size: 38,
            color: count == 0 ? null : coralFor(context),
            onTap: onDelete,
            tooltip: '删除',
          ),
        ],
      ),
    );
  }
}

class _PlaylistHero extends StatelessWidget {
  const _PlaylistHero({
    required this.playlist,
    required this.icon,
    required this.onPlayAll,
    required this.onShuffle,
    this.onImportLocal,
  });

  final Playlist playlist;
  final IconData icon;
  final VoidCallback onPlayAll;
  final VoidCallback onShuffle;
  final VoidCallback? onImportLocal;

  @override
  Widget build(BuildContext context) {
    final empty = playlist.songs.isEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(kGutter, 8, kGutter, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Container(
                width: 118,
                height: 118,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(color: Color(0x59000000), blurRadius: 26, offset: Offset(0, 14)),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      GradientArt(
                        seed: 'pl:${playlist.id}:${playlist.name}',
                        radius: 22,
                        decorate: true,
                        showMark: true,
                        mark: '',
                      ),
                      Center(
                        child: Icon(
                          icon,
                          size: 40,
                          color: playlist.id == 'love'
                              ? Colors.white.withValues(alpha: 0.92)
                              : Colors.white.withValues(alpha: 0.85),
                        ),
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
                    Overline('PLAYLIST'),
                    const SizedBox(height: 6),
                    Text(
                      playlist.name,
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
                      '${playlist.songs.length} 首歌曲',
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
                  onTap: empty ? null : onPlayAll,
                  expand: true,
                ),
              ),
              const SizedBox(width: 10),
              IconBtn(
                icon: CupertinoIcons.shuffle,
                size: 44,
                onTap: empty ? null : onShuffle,
                tooltip: '随机播放',
              ),
              if (onImportLocal != null) ...<Widget>[
                const SizedBox(width: 10),
                IconBtn(
                  icon: CupertinoIcons.folder,
                  size: 44,
                  onTap: onImportLocal,
                  tooltip: '导入本地音乐',
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
