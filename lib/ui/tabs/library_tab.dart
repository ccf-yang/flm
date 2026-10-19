import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../models/playlist.dart';
import '../../services/backup_service.dart';
import '../../state/library_state.dart';
import '../kit.dart';
import '../root_shell.dart' show kRootChromeSpace;
import '../screens/custom_sources_screen.dart';
import '../screens/playlist_detail_screen.dart';
import '../screens/settings_screen.dart';

class LibraryTab extends StatelessWidget {
  const LibraryTab({super.key});

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryState>();
    final top = MediaQuery.paddingOf(context).top + 10;

    return Scaffold(
      body: ListView(
        padding: EdgeInsets.fromLTRB(kGutter, top, kGutter, kRootChromeSpace),
        children: <Widget>[
          ScreenHead(
            overline: 'Collection / 07',
            title: '我的',
            subtitle: '所有喜欢的声音，都在这里。',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconBtn(
                  icon: CupertinoIcons.capsule,
                  tooltip: '自定义源',
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const CustomSourcesScreen()),
                    );
                  },
                ),
                const SizedBox(width: 8),
                IconBtn(
                  icon: CupertinoIcons.gear,
                  tooltip: '设置',
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _LocalMusicHero(
            count: library.localPlaylist.songs.length,
            onTap: () => _openPlaylist(context, library.localPlaylist),
            onImport: () => _importLocal(context, library),
          ),
          SectionHead(
            title: '我的列表',
            actionLabel: '新建',
            actionIcon: CupertinoIcons.plus,
            onAction: () => _createPlaylist(context, library),
          ),
          for (var i = 0; i < library.userPlaylists.length; i++)
            _LibraryRow(
              icon: CupertinoIcons.music_albums,
              name: library.userPlaylists[i].name,
              caption: '${library.userPlaylists[i].songs.length} 首',
              last: i == library.userPlaylists.length - 1,
              onTap: () => _openPlaylist(context, library.userPlaylists[i]),
              onMore: () => _showPlaylistMenu(context, library, library.userPlaylists[i]),
            ),
          if (library.userPlaylists.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
              child: Text(
                '还没有自建列表，点「新建」创建一个。',
                style: TextStyle(fontSize: 11.5, color: faintFor(context)),
              ),
            ),
          SectionHead(title: '收藏与试听', note: '同步自本机'),
          _LibraryRow(
            icon: CupertinoIcons.music_note_list,
            accentIcon: true,
            name: library.defaultPlaylist.name,
            caption: '${library.defaultPlaylist.songs.length} 首 · 播放时自动收录',
            onTap: () => _openPlaylist(context, library.defaultPlaylist),
          ),
          _LibraryRow(
            icon: CupertinoIcons.heart_fill,
            accentIcon: true,
            iconColor: coralFor(context),
            name: library.lovePlaylist.name,
            caption: '${library.lovePlaylist.songs.length} 首',
            last: true,
            onTap: () => _openPlaylist(context, library.lovePlaylist),
          ),
          SectionHead(title: '工具', note: '数据与音源'),
          _ToolsGrid(
            children: <Widget>[
              _ToolCard(
                icon: CupertinoIcons.folder,
                title: '导入本地音乐',
                caption: '从「文件」选择音频',
                onTap: () => _importLocal(context, library),
              ),
              _ToolCard(
                icon: CupertinoIcons.square_arrow_up,
                title: '导出备份',
                caption: '列表、音源与设置',
                onTap: () => _exportBackup(context, context.read<BackupService>()),
              ),
              _ToolCard(
                icon: CupertinoIcons.square_arrow_down,
                title: '导入备份',
                caption: '恢复本机数据',
                onTap: () => _importBackup(context, context.read<BackupService>()),
              ),
              _ToolCard(
                icon: CupertinoIcons.capsule,
                title: '自定义源',
                caption: '管理 .js 播放脚本',
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const CustomSourcesScreen()),
                  );
                },
              ),
            ],
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
    final name = await flmInputDialog(
      context,
      title: '新建列表',
      message: '给这个列表起一个名字。',
      placeholder: '列表名称',
      confirmLabel: '创建',
    );
    if (name == null || name.trim().isEmpty) return;
    library.createPlaylist(name.trim());
    flmToast(context, '已创建「${name.trim()}」');
  }

  Future<void> _showPlaylistMenu(
    BuildContext context,
    LibraryState library,
    Playlist playlist,
  ) async {
    await showFlmSheet<void>(
      context,
      title: playlist.name,
      child: Builder(
        builder: (sheetContext) => Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SheetAction(
              icon: CupertinoIcons.doc,
              label: '重命名',
              onTap: () {
                Navigator.pop(sheetContext);
                _renamePlaylist(context, library, playlist);
              },
            ),
            SheetAction(
              icon: CupertinoIcons.trash,
              label: '删除列表',
              danger: true,
              onTap: () async {
                Navigator.pop(sheetContext);
                final confirmed = await flmConfirmDialog(
                  context,
                  title: '删除列表',
                  message:
                      '确定要删除「${playlist.name}」及其中的 ${playlist.songs.length} 首歌曲吗？此操作不可撤销。',
                  confirmLabel: '删除',
                  danger: true,
                );
                if (confirmed) {
                  library.deletePlaylist(playlist.id);
                  flmToast(context, '已删除「${playlist.name}」');
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _renamePlaylist(
    BuildContext context,
    LibraryState library,
    Playlist playlist,
  ) async {
    final name = await flmInputDialog(
      context,
      title: '重命名列表',
      message: '修改后会立即更新列表名称。',
      initialValue: playlist.name,
      confirmLabel: '保存',
    );
    if (name == null || name.trim().isEmpty) return;
    library.renamePlaylist(playlist.id, name.trim());
  }

  Future<void> _importLocal(BuildContext context, LibraryState library) async {
    try {
      final count = await library.importLocalMusic();
      if (!context.mounted) return;
      flmToast(context, count == 0 ? '没有导入任何歌曲' : '已导入 $count 首本地歌曲');
    } catch (error) {
      if (!context.mounted) return;
      flmToast(context, '导入失败: $error');
    }
  }

  Future<void> _exportBackup(BuildContext context, BackupService backup) async {
    try {
      final path = await backup.exportToFile();
      if (!context.mounted) return;
      final copy = await flmConfirmDialog(
        context,
        title: '备份已生成',
        message: path,
        cancelLabel: '关闭',
        confirmLabel: '复制路径',
      );
      if (copy) {
        Clipboard.setData(ClipboardData(text: path));
        if (context.mounted) flmToast(context, '已复制备份路径');
      }
    } catch (error) {
      if (!context.mounted) return;
      flmToast(context, '导出失败: $error');
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
      flmToast(context, '已恢复 ${parts.join('、')}');
    } catch (error) {
      if (!context.mounted) return;
      flmToast(context, '导入失败: $error');
    }
  }
}

class _LocalMusicHero extends StatelessWidget {
  const _LocalMusicHero({
    required this.count,
    required this.onTap,
    required this.onImport,
  });

  final int count;
  final VoidCallback onTap;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 142),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(25),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[Color(0xFF0B5F59), Color(0xFF0E9384), Color(0xFF54D8B7)],
            stops: <double>[0, 0.49, 1],
          ),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x380E9384),
              blurRadius: 50,
              offset: Offset(0, 22),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: <Widget>[
            Positioned(
              right: -48,
              top: -72,
              child: _HeroRing(size: 180),
            ),
            Positioned(
              right: -18,
              top: -38,
              child: _HeroRing(size: 110),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'ON THIS DEVICE',
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.44,
                    color: Color(0xA8FFFFFF),
                  ),
                ),
                const SizedBox(height: 7),
                const Text(
                  '本地音乐',
                  style: TextStyle(
                    fontSize: 26,
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1.17,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '$count 首 · 直接从设备文件导入',
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: Color(0xABFFFFFF),
                  ),
                ),
              ],
            ),
            Positioned(
              right: 16,
              bottom: 16,
              child: Pressable(
                onTap: onImport,
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
                  ),
                  child: const Text(
                    '导入',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
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

class _HeroRing extends StatelessWidget {
  const _HeroRing({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
    );
  }
}

class _LibraryRow extends StatelessWidget {
  const _LibraryRow({
    required this.icon,
    required this.name,
    required this.caption,
    required this.onTap,
    this.onMore,
    this.last = false,
    this.accentIcon = false,
    this.iconColor,
  });

  final IconData icon;
  final String name;
  final String caption;
  final VoidCallback onTap;
  final VoidCallback? onMore;
  final bool last;
  final bool accentIcon;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          border: Border(
            bottom: last ? BorderSide.none : BorderSide(color: lineColor(context)),
          ),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: accentIcon ? accentSoftColor(context) : surface2For(context),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                size: 19,
                color: iconColor ?? accentFor(context),
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
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: textFor(context),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: faintFor(context)),
                  ),
                ],
              ),
            ),
            if (onMore != null)
              Pressable(
                onTap: onMore,
                child: SizedBox(
                  width: 30,
                  height: 30,
                  child: Icon(
                    CupertinoIcons.ellipsis,
                    size: 15,
                    color: faintFor(context),
                  ),
                ),
              )
            else
              Icon(CupertinoIcons.chevron_right, size: 14, color: faintFor(context)),
            const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }
}

class _ToolsGrid extends StatelessWidget {
  const _ToolsGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += 2) {
      rows.add(
        Padding(
          padding: EdgeInsets.only(bottom: i + 2 < children.length ? 9 : 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(child: children[i]),
              const SizedBox(width: 9),
              if (i + 1 < children.length)
                Expanded(child: children[i + 1])
              else
                const Expanded(child: SizedBox()),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(children: rows),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({
    required this.icon,
    required this.title,
    required this.caption,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String caption;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 92),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: surfaceFor(context),
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: lineColor(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: accentSoftColor(context),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 15, color: accentFor(context)),
            ),
            const SizedBox(height: 9),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: textFor(context),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9,
                height: 1.4,
                color: faintFor(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
