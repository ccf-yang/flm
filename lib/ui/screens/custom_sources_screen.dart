import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../models/custom_source.dart';
import '../../state/source_state.dart';
import '../widgets/empty_state.dart';

class CustomSourcesScreen extends StatelessWidget {
  const CustomSourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<SourceState>();
    final activeId = state.active?.id;
    return Scaffold(
      appBar: AppBar(
        title: const Text('自定义源'),
        actions: <Widget>[
          IconButton(
            tooltip: '导入脚本',
            onPressed: () => _showImportMenu(context, state),
            icon: const Icon(Icons.add_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          if (state.loading || state.importing)
            const LinearProgressIndicator(minHeight: 2),
          _StatusCard(state: state),
          const SectionHeader(title: '已导入的源'),
          if (state.sources.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: EmptyState(
                title: '还没有自定义源',
                message: '导入 .js 音源脚本后，才能播放在线歌曲',
                icon: Icons.extension_outlined,
              ),
            )
          else
            ...state.sources.map((source) {
              final active = source.id == activeId;
              return ListTile(
                onTap: () => _activate(context, state, source),
                leading: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: surfaceHighFor(context),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.extension_rounded,
                    color: active ? AppColors.accent : mutedFor(context),
                  ),
                ),
                title: Text(
                  source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: active ? AppColors.accent : textFor(context),
                  ),
                ),
                subtitle: Text(
                  <String>[
                    if (source.version.isNotEmpty) 'v${source.version}',
                    if (source.author.isNotEmpty) source.author,
                    if (source.createdAt > 0) _dateLabel(source.createdAt),
                  ].join(' · '),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (active)
                      const Icon(Icons.check_circle_rounded, color: AppColors.accent),
                    IconButton(
                      tooltip: '删除',
                      onPressed: () => _delete(context, state, source),
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                    ),
                  ],
                ),
              );
            }),
          if (state.sources.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.block_rounded),
              title: const Text('不使用自定义源'),
              subtitle: const Text('仍然可以浏览搜索、歌单、排行榜和歌词'),
              trailing: activeId == null
                  ? const Icon(Icons.check_rounded, color: AppColors.accent)
                  : null,
              onTap: () => state.setActive(null),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: FilledButton.icon(
              onPressed: () => _showImportMenu(context, state),
              icon: const Icon(Icons.file_open_rounded),
              label: const Text('导入自定义源（本地 / URL）'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Text(
              '说明：脚本只在本地 WebView 沙箱中运行，用于把歌曲信息转换为音频链接。'
              'flm 不内置任何音源，也不对脚本内容负责。',
              style: TextStyle(fontSize: 12, height: 1.5, color: mutedFor(context)),
            ),
          ),
        ],
      ),
    );
  }

  String _dateLabel(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Future<void> _showImportMenu(BuildContext context, SourceState state) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.file_open_rounded),
                title: const Text('本地导入'),
                subtitle: const Text('从「文件」App 选择 .js 音源脚本'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _import(context, state);
                },
              ),
              ListTile(
                leading: const Icon(Icons.link_rounded),
                title: const Text('在线导入'),
                subtitle: const Text('填写脚本的 http / https 直链地址'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _importFromUrl(context, state);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _importFromUrl(BuildContext context, SourceState state) async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('在线导入自定义源'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '填写 .js 音源脚本的直链地址，例如 GitHub Raw。',
                style: TextStyle(fontSize: 12, color: mutedFor(dialogContext)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  hintText: 'https://example.com/source.js',
                ),
                onSubmitted: (value) => Navigator.pop(dialogContext, value),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('下载并导入'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (url == null || url.trim().isEmpty) return;

    try {
      final info = await state.importSourceFromUrl(url);
      if (info == null) return;
      if (state.active == null) {
        await state.setActive(info);
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入「${info.name}」')),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('在线导入失败: $error')),
      );
    }
  }

  Future<void> _import(BuildContext context, SourceState state) async {
    try {
      final info = await state.importSource();
      if (info == null) return;
      if (state.active == null) {
        await state.setActive(info);
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入「${info.name}」')),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $error')),
      );
    }
  }

  Future<void> _activate(
    BuildContext context,
    SourceState state,
    CustomSourceInfo source,
  ) async {
    await state.setActive(source);
    if (!context.mounted) return;
    if (state.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('启用失败: ${state.error}')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已启用「${source.name}」')),
      );
    }
  }

  Future<void> _delete(
    BuildContext context,
    SourceState state,
    CustomSourceInfo source,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除自定义源'),
        content: Text('确定要删除「${source.name}」吗？'),
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
    if (!context.mounted) return;
    await state.deleteSource(source.id);
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state});

  final SourceState state;

  @override
  Widget build(BuildContext context) {
    final active = state.active;
    final error = state.error;
    final capabilities = state.capabilities;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Color background;
    Color foreground;
    String title;
    String message;
    IconData icon;

    if (active == null) {
      background = isDark ? const Color(0xFF2A2415) : const Color(0xFFFFF7E6);
      foreground = isDark ? const Color(0xFFF5D58B) : const Color(0xFF9A6700);
      title = '未启用自定义源';
      message = '搜索和歌单可以正常浏览，但在线播放需要先启用一个音源脚本。';
      icon = Icons.info_outline_rounded;
    } else if (error != null) {
      background = AppColors.danger.withValues(alpha: 0.1);
      foreground = AppColors.danger;
      title = '${active.name} 初始化失败';
      message = error;
      icon = Icons.error_outline_rounded;
    } else if (state.loading) {
      background = AppColors.accent.withValues(alpha: 0.1);
      foreground = AppColors.accent;
      title = '${active.name} 初始化中';
      message = '正在加载脚本并读取支持的音乐平台…';
      icon = Icons.hourglass_empty_rounded;
    } else if (capabilities.isEmpty) {
      background = AppColors.danger.withValues(alpha: 0.1);
      foreground = AppColors.danger;
      title = '${active.name} 尚未就绪';
      message = '脚本没有返回可用的音源能力，请检查脚本是否完整。';
      icon = Icons.warning_amber_rounded;
    } else {
      background = AppColors.accent.withValues(alpha: 0.1);
      foreground = AppColors.accent;
      title = '${active.name} 已启用';
      message = '可用的平台：${capabilities.sources.keys.map((item) => item.toUpperCase()).join('、')}';
      icon = Icons.check_circle_outline_rounded;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, color: foreground),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: foreground,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: foreground.withValues(alpha: 0.9),
                    ),
                  ),
                  if (capabilities.sources.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: capabilities.sources.entries.map((entry) {
                        final actions = entry.value['actions'];
                        final actionText = actions is List ? actions.join('/') : '';
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: foreground.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${entry.key.toUpperCase()} · $actionText',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: foreground,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
