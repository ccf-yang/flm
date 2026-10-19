import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../models/playlist.dart';
import '../../services/backup_service.dart';
import '../../state/library_state.dart';
import '../screens/custom_sources_screen.dart';
import '../screens/playlist_detail_screen.dart';
import '../screens/settings_screen.dart';
import '../widgets/empty_state.dart';

class LibraryTab extends StatelessWidget {
  const LibraryTab({super.key});

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的'),
        actions: <Widget>[
          IconButton(
            tooltip: '自定义源',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const CustomSourcesScreen()),
              );
            },
            icon: const Icon(Icons.extension_rounded),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              );
            },
            icon: const Icon(Icons.settings_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: <Widget>[
          _LocalMusicCard(
            count: library.localPlaylist.songs.length,
            onTap: () => _openPlaylist(context, library.localPlaylist),
            onImport: () => _importLocal(context, library),
          ),
          SectionHeader(
            title: '我的列表',
            trailing: TextButton.icon(
              onPressed: () => _createPlaylist(context, library),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('新建'),
            ),
          ),
          ...library.userPlaylists.map(
            (playlist) => _PlaylistTile(
              playlist: playlist,
              onTap: () => _openPlaylist(context, playlist),
              onMore: () => _showPlaylistMenu(context, library, playlist),
            ),
          ),
          if (library.userPlaylists.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '还没有自建列表，点右上角「新建」创建一个。',
                style: TextStyle(fontSize: 13, color: mutedFor(context)),
              ),
            ),
          const SectionHeader(title: '收藏与试听'),
          _PlaylistTile(
            playlist: library.defaultPlaylist,
            icon: Icons.playlist_play_rounded,
            onTap: () => _openPlaylist(context, library.defaultPlaylist),
          ),
          _PlaylistTile(
            playlist: library.lovePlaylist,
            icon: Icons.favorite_rounded,
            onTap: () => _openPlaylist(context, library.lovePlaylist),
          ),
          const SectionHeader(title: '工具'),
          ListTile(
            leading: const Icon(Icons.folder_open_rounded),
            title: const Text('导入本地音乐'),
            subtitle: const Text('从「文件」App 选择音频，复制到 flm 沙盒'),
            onTap: () => _importLocal(context, library),
          ),
          ListTile(
            leading: const Icon(Icons.ios_share_rounded),
            title: const Text('导出备份'),
            subtitle: const Text('列表 + 自定义源 + 设置，生成到 Documents'),
            onTap: () => _exportBackup(context, context.read<BackupService>()),
          ),
          ListTile(
            leading: const Icon(Icons.restore_rounded),
            title: const Text('导入备份'),
            subtitle: const Text('恢复列表、自定义源和设置'),
            onTap: () => _importBackup(context, context.read<BackupService>()),
          ),
          ListTile(
            leading: const Icon(Icons.extension_rounded),
            title: const Text('自定义源'),
            subtitle: const Text('管理用于获取在线播放链接的 .js 脚本'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const CustomSourcesScreen()),
              );
            },
          ),
        ],
      ),
    );
  }

  void _openPlaylist(BuildContext context, Playlist playlist) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlaylistDetailScreen(playlistId: playlist.id),
      ),
    );
  }

  Future<void> _createPlaylist(BuildContext context, LibraryState library) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('新建列表'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '列表名称'),
            onSubmitted: (value) => Navigator.pop(dialogContext, value),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('创建'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    library.createPlaylist(name.trim());
  }

  Future<void> _showPlaylistMenu(
    BuildContext context,
    LibraryState library,
    Playlist playlist,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('重命名'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await _renamePlaylist(context, library, playlist);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                title: const Text('删除列表', style: TextStyle(color: AppColors.danger)),
                onTap: () async {
                  Navigator.pop(sheetContext);
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
                  if (confirmed == true) library.deletePlaylist(playlist.id);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _renamePlaylist(
    BuildContext context,
    LibraryState library,
    Playlist playlist,
  ) async {
    final controller = TextEditingController(text: playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名列表'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '列表名称'),
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
    if (name == null || name.trim().isEmpty) return;
    library.renamePlaylist(playlist.id, name.trim());
  }

  Future<void> _importLocal(BuildContext context, LibraryState library) async {
    try {
      final count = await library.importLocalMusic();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(count == 0 ? '没有导入任何歌曲' : '已导入 $count 首本地歌曲')),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $error')),
      );
    }
  }

  Future<void> _exportBackup(BuildContext context, BackupService backup) async {
    try {
      final path = await backup.exportToFile();
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('备份已生成'),
          content: SelectableText(path),

          actions: <Widget>[
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: path));
                Navigator.pop(dialogContext);
              },
              child: const Text('复制路径'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('好'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败: $error')),
      );
    }
  }

  Future<void> _importBackup(BuildContext context, BackupService backup) async {
    try {
      final result = await backup.importFromFile();
      if (!context.mounted) return;
      if (result.isEmpty) return;
      final parts = <String>[
        '${result.playlists} 个列表',
        '${result.sources} 个自定义源',
        if (result.settings) '设置',
      ];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已恢复 ${parts.join('、')}')),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $error')),
      );
    }
  }
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({
    required this.playlist,
    required this.onTap,
    this.onMore,
    this.icon,
  });

  final Playlist playlist;
  final VoidCallback onTap;
  final VoidCallback? onMore;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: surfaceHighFor(context),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon ?? Icons.queue_music_rounded,
          color: AppColors.accent,
        ),
      ),
      title: Text(
        playlist.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: textFor(context),
        ),
      ),
      subtitle: Text('${playlist.songs.length} 首'),
      trailing: onMore == null
          ? const Icon(Icons.chevron_right_rounded)
          : IconButton(
              onPressed: onMore,
              icon: const Icon(Icons.more_horiz_rounded),
            ),
    );
  }
}

class _LocalMusicCard extends StatelessWidget {
  const _LocalMusicCard({
    required this.count,
    required this.onTap,
    required this.onImport,
  });

  final int count;
  final VoidCallback onTap;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[Color(0xFF0F766E), Color(0xFF14B8A6)],
            ),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.folder_special_rounded, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      '本地音乐',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$count 首 · 直接从设备文件导入',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.82),
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: onImport,
                style: TextButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.16),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
                child: const Text('导入'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
