import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../models/app_settings.dart';
import '../../services/backup_service.dart';
import '../../state/app_state.dart';
import '../../state/library_state.dart';
import '../../state/player_state.dart';
import '../../state/source_state.dart';
import '../widgets/empty_state.dart';
import 'custom_sources_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final playMode = context.select<PlayerController, PlayMode>(
      (player) => player.playMode,
    );
    final library = context.watch<LibraryState>();
    final sourceState = context.watch<SourceState>();
    final settings = appState.settings;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          const SectionHeader(title: '外观'),
          ListTile(
            leading: const Icon(Icons.brightness_6_rounded),
            title: const Text('主题模式'),
            subtitle: Text(_themeLabel(settings.themeMode)),
            onTap: () => _pickOption(
              context,
              title: '主题模式',
              current: settings.themeMode,
              options: const <Map<String, String>>[
                <String, String>{'id': 'system', 'name': '跟随系统'},
                <String, String>{'id': 'light', 'name': '浅色'},
                <String, String>{'id': 'dark', 'name': '深色'},
              ],
              onSelected: (value) => appState.setThemeMode(value),
            ),
          ),
          const SectionHeader(title: '播放'),
          ListTile(
            leading: const Icon(Icons.high_quality_rounded),
            title: const Text('优先音质'),
            subtitle: Text(_qualityLabel(settings.quality)),
            onTap: () => _pickOption(
              context,
              title: '优先音质',
              current: settings.quality,
              options: const <Map<String, String>>[
                <String, String>{'id': '128k', 'name': '标准 128k'},
                <String, String>{'id': '320k', 'name': '高品质 320k'},
                <String, String>{'id': 'flac', 'name': '无损 FLAC'},
                <String, String>{'id': 'flac24bit', 'name': '24bit FLAC'},
              ],
              onSelected: (value) {
                appState.update((settings) => settings.quality = value);
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.repeat_rounded),
            title: const Text('播放模式'),
            subtitle: Text(playMode.label),
            onTap: () async {
              await _pickOption(
                context,
                title: '播放模式',
                current: playMode.name,
                options: PlayMode.values
                    .map((mode) => <String, String>{'id': mode.name, 'name': mode.label})
                    .toList(),
                onSelected: (value) {
                  final mode = PlayMode.values.firstWhere((item) => item.name == value);
                  context.read<PlayerController>().setPlayMode(mode);
                },
              );
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.history_rounded),
            title: const Text('记住播放进度'),
            subtitle: const Text('下次打开应用时恢复上次播放的歌曲和位置'),
            value: settings.saveProgress,
            onChanged: (value) {
              appState.update((settings) => settings.saveProgress = value);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.play_circle_outline_rounded),
            title: const Text('启动后自动播放'),
            subtitle: const Text('恢复上次播放时立即开始播放'),
            value: settings.autoPlayOnStart,
            onChanged: (value) {
              appState.update((settings) => settings.autoPlayOnStart = value);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.translate_rounded),
            title: const Text('显示歌词翻译'),
            subtitle: const Text('如果歌词提供翻译，会在原文下方显示'),
            value: settings.showTranslation,
            onChanged: (value) {
              appState.update((settings) => settings.showTranslation = value);
              context.read<PlayerController>().reloadLyrics();
            },
          ),
          ListTile(
            leading: const Icon(Icons.block_rounded),
            title: const Text('不喜欢规则'),
            subtitle: Text('${settings.dislikedKeys.length} 条'),
            trailing: settings.dislikedKeys.isEmpty
                ? null
                : TextButton(
                    onPressed: () {
                      appState.clearDislikes();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已清空不喜欢规则')),
                      );
                    },
                    child: const Text('清空'),
                  ),
          ),
          const SectionHeader(title: '数据'),
          ListTile(
            leading: const Icon(Icons.folder_open_rounded),
            title: const Text('导入本地音乐'),
            onTap: () => _importLocal(context, library),
          ),
          ListTile(
            leading: const Icon(Icons.ios_share_rounded),
            title: const Text('导出备份'),
            subtitle: const Text('列表 + 自定义源（含 URL/脚本）+ 设置'),
            onTap: () => _exportBackup(context, context.read<BackupService>()),
          ),
          ListTile(
            leading: const Icon(Icons.restore_rounded),
            title: const Text('导入备份'),
            subtitle: const Text('恢复列表、自定义源和设置'),
            onTap: () => _importBackup(context, context.read<BackupService>()),
          ),
          const SectionHeader(title: '音源'),
          ListTile(
            leading: const Icon(Icons.extension_rounded),
            title: const Text('自定义源'),
            subtitle: Text(_sourceSubtitle(sourceState)),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const CustomSourcesScreen()),
              );
            },
          ),
          const SectionHeader(title: '关于'),
          const ListTile(
            leading: Icon(Icons.info_outline_rounded),
            title: Text('flm'),
            subtitle: Text('版本 1.0.0 · 基于 LX Music 音乐源协议'),
          ),
          ListTile(
            leading: const Icon(Icons.code_rounded),
            title: const Text('LX Music 项目'),
            subtitle: const Text('github.com/lyswhut/lx-music-mobile'),
            onTap: () async {
              await launchUrl(
                Uri.parse('https://github.com/lyswhut/lx-music-mobile'),
                mode: LaunchMode.externalApplication,
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.cloud_sync_rounded),
            title: const Text('LX 同步服务'),
            subtitle: const Text('github.com/lyswhut/lx-music-sync-server'),
            onTap: () async {
              await launchUrl(
                Uri.parse('https://github.com/lyswhut/lx-music-sync-server'),
                mode: LaunchMode.externalApplication,
              );
            },
          ),
        ],
      ),
    );
  }

  String _themeLabel(String mode) {
    switch (mode) {
      case 'light':
        return '浅色';
      case 'dark':
        return '深色';
      default:
        return '跟随系统';
    }
  }

  String _qualityLabel(String quality) {
    switch (quality) {
      case '128k':
        return '标准 128k';
      case 'flac':
        return '无损 FLAC';
      case 'flac24bit':
        return '24bit FLAC';
      default:
        return '高品质 320k';
    }
  }

  String _sourceSubtitle(SourceState state) {
    final active = state.active;
    if (active == null) return '未启用 · 在线播放需要先导入音源脚本';
    if (state.loading) return '${active.name} · 初始化中…';
    if (state.error != null) return '${active.name} · ${state.error}';
    return '${active.name} · 已启用';
  }

  Future<void> _pickOption(
    BuildContext context, {
    required String title,
    required String current,
    required List<Map<String, String>> options,
    required ValueChanged<String> onSelected,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: textFor(sheetContext),
                    ),
                  ),
                ),
              ),
              ...options.map((option) {
                final active = option['id'] == current;
                return ListTile(
                  title: Text(option['name'] ?? ''),
                  trailing: active
                      ? const Icon(Icons.check_rounded, color: AppColors.accent)
                      : null,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    onSelected(option['id'] ?? '');
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
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
