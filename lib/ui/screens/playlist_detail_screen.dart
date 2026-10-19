import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../state/library_state.dart';
import '../../state/player_state.dart';
import '../widgets/empty_state.dart';
import '../widgets/song_actions_sheet.dart';
import '../widgets/active_song_tile.dart';

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
        appBar: AppBar(title: const Text('列表')),
        body: const EmptyState(title: '列表不存在', icon: Icons.queue_music_rounded),
      );
    }

    final songs = _showSearch && _searchController.text.trim().isNotEmpty
        ? library.searchInPlaylist(playlist.id, _searchController.text)
        : playlist.songs;

    return Scaffold(
      appBar: AppBar(
        leading: _selecting
            ? IconButton(
                onPressed: _exitSelection,
                icon: const Icon(Icons.close_rounded),
              )
            : null,
        title: Text(
          _selecting ? '已选择 ${_selected.length} 首' : playlist.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: _selecting
            ? <Widget>[
                IconButton(
                  tooltip: '全选',
                  onPressed: () {
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
                  icon: const Icon(Icons.select_all_rounded),
                ),
                IconButton(
                  tooltip: '添加到列表',
                  onPressed: _selected.isEmpty
                      ? null
                      : () {
                          showSongsToPlaylist(
                            context,
                            songs.where((song) => _selected.contains(song.id)).toList(),
                          );
                          _exitSelection();
                        },
                  icon: const Icon(Icons.playlist_add_rounded),
                ),
                IconButton(
                  tooltip: '删除',
                  onPressed: _selected.isEmpty
                      ? null
                      : () => _deleteSelected(playlist, songs),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
                const SizedBox(width: 4),
              ]
            : _reorderMode
                ? <Widget>[
                    IconButton(
                      tooltip: '完成',
                      onPressed: () => setState(() => _reorderMode = false),
                      icon: const Icon(Icons.check_rounded),
                    ),
                    const SizedBox(width: 4),
                  ]
                : <Widget>[
                    IconButton(
                      tooltip: '搜索',
                      onPressed: () {
                        setState(() => _showSearch = !_showSearch);
                        if (!_showSearch) {
                          _searchController.clear();
                        }
                      },
                      icon: Icon(_showSearch ? Icons.search_off_rounded : Icons.search_rounded),
                    ),
                    IconButton(
                      tooltip: '播放全部',
                      onPressed: playlist.songs.isEmpty ? null : () => _playAll(playlist),
                      icon: const Icon(Icons.play_circle_fill_rounded),
                    ),
                    IconButton(
                      tooltip: '更多',
                      onPressed: () => _showMoreMenu(playlist),
                      icon: const Icon(Icons.more_horiz_rounded),
                    ),
                    const SizedBox(width: 4),
                  ],
      ),
      body: Column(
        children: <Widget>[
          if (_showSearch)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: '在列表中搜索',
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  fillColor: surfaceHighFor(context),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          Expanded(
            child: _reorderMode
                ? _buildReorderList(playlist, library)
                : _buildList(playlist, songs, library),
          ),
        ],
      ),
    );
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
        icon: Icons.queue_music_rounded,
        action: playlist.id == 'local'
            ? FilledButton.icon(
                onPressed: () => _importLocal(),
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('导入本地音乐'),
              )
            : null,
      );
    }
    if (songs.isEmpty) {
      return const EmptyState(title: '没有匹配的歌曲', icon: Icons.search_off_rounded);
    }
    return ListView.builder(
      itemCount: songs.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _PlaylistHeader(
            playlist: playlist,
            onPlayAll: () => _playAll(playlist),
            onShuffle: () => _shuffle(playlist),
            onImportLocal: playlist.id == 'local'
                ? () {
                    _importLocal();
                  }
                : null,
          );
        }
        final songIndex = index - 1;
        final song = songs[songIndex];
        return ActiveSongTile(
          song: song,
          index: songIndex,
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
    );
  }

  Widget _buildReorderList(Playlist playlist, LibraryState library) {
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.only(bottom: 24),
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
          child: ActiveSongTile(
            song: song,
            index: index,
            trailing: ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                child: Icon(Icons.drag_handle_rounded, color: mutedFor(context)),
              ),
            ),
          ),
        );
      },
    );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(count == 0 ? '没有导入任何歌曲' : '已导入 $count 首本地歌曲')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $error')),
      );
    }
  }

  Future<void> _deleteSelected(Playlist playlist, List<Song> songs) async {
    final songsToDelete = songs.where((song) => _selected.contains(song.id)).toList();
    if (songsToDelete.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除歌曲'),
        content: Text('确定要从「${playlist.name}」中删除所选的 ${songsToDelete.length} 首歌曲吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    context.read<LibraryState>().removeSongs(
          playlist.id,
          songsToDelete.map((song) => song.id).toSet(),
        );
    _exitSelection();
  }

  Future<void> _showMoreMenu(Playlist playlist) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (!playlist.isBuiltIn) ...<Widget>[
                ListTile(
                  leading: const Icon(Icons.edit_rounded),
                  title: const Text('重命名'),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    await _rename(playlist);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                  title: const Text('删除列表', style: TextStyle(color: AppColors.danger)),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    await _deletePlaylist(playlist);
                  },
                ),
              ],
              ListTile(
                leading: const Icon(Icons.sort_rounded),
                title: const Text('按歌名排序（升序）'),
                onTap: () {
                  context.read<LibraryState>().sortPlaylist(playlist.id, 'name', true);
                  Navigator.pop(sheetContext);
                },
              ),
              ListTile(
                leading: const Icon(Icons.sort_rounded),
                title: const Text('按歌名排序（降序）'),
                onTap: () {
                  context.read<LibraryState>().sortPlaylist(playlist.id, 'name', false);
                  Navigator.pop(sheetContext);
                },
              ),
              ListTile(
                leading: const Icon(Icons.person_outline_rounded),
                title: const Text('按艺术家排序'),
                onTap: () {
                  context.read<LibraryState>().sortPlaylist(playlist.id, 'singer', true);
                  Navigator.pop(sheetContext);
                },
              ),
              ListTile(
                leading: const Icon(Icons.album_outlined),
                title: const Text('按专辑排序'),
                onTap: () {
                  context.read<LibraryState>().sortPlaylist(playlist.id, 'album', true);
                  Navigator.pop(sheetContext);
                },
              ),
              ListTile(
                leading: const Icon(Icons.swap_vert_rounded),
                title: const Text('手动调整顺序'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  setState(() => _reorderMode = true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.clear_all_rounded),
                title: const Text('清空列表'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await _clearPlaylist(playlist);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _rename(Playlist playlist) async {
    final controller = TextEditingController(text: playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名列表'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;
    context.read<LibraryState>().renamePlaylist(playlist.id, name.trim());
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除列表'),
        content: Text('确定要删除「${playlist.name}」及其中的所有歌曲吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    context.read<LibraryState>().deletePlaylist(playlist.id);
    Navigator.of(context).pop();
  }

  Future<void> _clearPlaylist(Playlist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空列表'),
        content: Text('确定要清空「${playlist.name}」中的所有歌曲吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    context.read<LibraryState>().removeSongs(
          playlist.id,
          playlist.songs.map((song) => song.id).toSet(),
        );
  }
}

class _PlaylistHeader extends StatelessWidget {
  const _PlaylistHeader({
    required this.playlist,
    required this.onPlayAll,
    required this.onShuffle,
    this.onImportLocal,
  });

  final Playlist playlist;
  final VoidCallback onPlayAll;
  final VoidCallback onShuffle;
  final VoidCallback? onImportLocal;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 86,
                height: 86,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[Color(0xFF0F766E), Color(0xFF14B8A6)],
                  ),
                ),
                child: Icon(
                  playlist.id == 'love'
                      ? Icons.favorite_rounded
                      : playlist.id == 'local'
                          ? Icons.folder_special_rounded
                          : Icons.queue_music_rounded,
                  size: 38,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      playlist.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: textFor(context),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${playlist.songs.length} 首歌曲',
                      style: TextStyle(fontSize: 12, color: mutedFor(context)),
                    ),
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
                  onPressed: playlist.songs.isEmpty ? null : onPlayAll,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('播放全部'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: playlist.songs.isEmpty ? null : onShuffle,
                icon: const Icon(Icons.shuffle_rounded, size: 18),
                label: const Text('随机'),
              ),
              if (onImportLocal != null) ...<Widget>[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '导入本地音乐',
                  onPressed: onImportLocal,
                  icon: const Icon(Icons.folder_open_rounded),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}
