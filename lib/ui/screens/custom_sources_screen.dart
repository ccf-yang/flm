import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../models/custom_source.dart';
import '../../state/source_state.dart';
import '../kit.dart';
import '../widgets/empty_state.dart';

class CustomSourcesScreen extends StatelessWidget {
  const CustomSourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<SourceState>();
    final activeId = state.active?.id;
    final onlineCount = state.sources
        .where((source) => (source.importUrl ?? '').trim().isNotEmpty)
        .length;
    return Scaffold(
      body: Stack(
        children: <Widget>[
          const Positioned.fill(child: AuroraBackground(deep: true)),
          SafeArea(
            bottom: false,
            child: Column(
              children: <Widget>[
                FlmNavBar(
                  leading: IconBtn(
                    icon: CupertinoIcons.chevron_left,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  title: '自定义源',
                  trailing: <Widget>[
                    if (onlineCount > 0)
                      IconBtn(
                        icon: CupertinoIcons.arrow_clockwise,
                        tooltip: '刷新全部在线源',
                        onTap:
                            state.importing ? null : () => _updateAll(context, state),
                      ),
                    IconBtn(
                      icon: CupertinoIcons.plus,
                      tooltip: '导入脚本',
                      onTap: () => _showImportMenu(context, state),
                    ),
                  ],
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 40),
                    children: <Widget>[
                      if (state.loading || state.importing)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: kGutter),
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      _StatusCard(state: state),
                      SectionHead(title: '已导入的源', note: '${state.sources.length} 个'),
                      if (state.sources.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 18),
                          child: EmptyState(
                            title: '还没有自定义源',
                            message: '导入 .js 音源脚本后，才能播放在线歌曲',
                            icon: CupertinoIcons.capsule,
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: kGutter),
                          child: Column(
                            children: <Widget>[
                              ...state.sources.map((source) {
                                final active = source.id == activeId;
                                return _SourceRow(
                                  source: source,
                                  active: active,
                                  onTap: () => _activate(context, state, source),
                                  onUpdate: source.importUrl == null
                                      ? null
                                      : () => _updateFromUrl(context, state, source),
                                  onDelete: () => _delete(context, state, source),
                                );
                              }),
                              const SizedBox(height: 4),
                              _NoSourceRow(
                                active: activeId == null,
                                onTap: () => state.setActive(null),
                              ),
                            ],
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(kGutter, 18, kGutter, 0),
                        child: AuroraButton(
                          label: '导入自定义源（本地 / URL）',
                          icon: CupertinoIcons.square_arrow_down,
                          onTap: () => _showImportMenu(context, state),
                          expand: true,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(kGutter, 16, kGutter, 0),
                        child: Text(
                          '说明：脚本只在本地 WebView 沙箱中运行，用于把歌曲信息转换为音频链接。'
                          'flm 不内置任何音源，也不对脚本内容负责。',
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.6,
                            color: faintFor(context),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showImportMenu(BuildContext context, SourceState state) async {
    await showFlmSheet<void>(
      context,
      title: '导入音源脚本',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SheetAction(
            icon: CupertinoIcons.folder,
            label: '本地导入',
            subtitle: '从「文件」App 选择 .js 音源脚本',
            onTap: () {
              Navigator.pop(context);
              _import(context, state);
            },
          ),
          SheetAction(
            icon: CupertinoIcons.square_arrow_down,
            label: '在线导入',
            subtitle: '填写脚本的 http / https 直链地址',
            onTap: () {
              Navigator.pop(context);
              _importFromUrl(context, state);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _importFromUrl(BuildContext context, SourceState state) async {
    final url = await flmInputDialog(
      context,
      title: '在线导入自定义源',
      message: '填写 .js 音源脚本的直链地址，例如 GitHub Raw。',
      placeholder: 'https://example.com/source.js',
      confirmLabel: '下载并导入',
    );
    if (url == null || url.isEmpty) return;

    try {
      final info = await state.importSourceFromUrl(url);
      if (info == null) return;
      if (state.active == null) {
        await state.setActive(info);
      }
      if (!context.mounted) return;
      flmToast(context, '已导入「${info.name}」');
    } catch (error) {
      if (!context.mounted) return;
      flmToast(context, '在线导入失败: $error');
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
      flmToast(context, '已导入「${info.name}」');
    } catch (error) {
      if (!context.mounted) return;
      flmToast(context, '导入失败: $error');
    }
  }

  Future<void> _activate(
    BuildContext context,
    SourceState state,
    CustomSourceInfo source,
  ) async {
    await state.setActive(source);
    if (!context.mounted) return;
    flmToast(context, '已选择「${source.name}」');
  }

  Future<void> _updateFromUrl(
    BuildContext context,
    SourceState state,
    CustomSourceInfo source,
  ) async {
    try {
      final updated = await state.updateSourceFromUrl(source);
      if (!context.mounted) return;
      flmToast(context, '已从原 URL 更新「${updated.name}」');
    } catch (error) {
      if (!context.mounted) return;
      flmToast(context, '更新失败: $error');
    }
  }

  Future<void> _updateAll(BuildContext context, SourceState state) async {
    final confirmed = await flmConfirmDialog(
      context,
      title: '刷新全部在线源',
      message: '按各自保存的原始 URL 重新下载脚本，并清掉旧引擎缓存重新加载。'
          '本地导入、没有记录 URL 的源会被跳过。',
      confirmLabel: '开始刷新',
    );
    if (!confirmed) return;
    if (!context.mounted) return;
    flmToast(context, '正在刷新在线源…');
    final result = await state.updateAllFromUrls();
    if (!context.mounted) return;
    if (result.failed.isEmpty) {
      flmToast(
        context,
        result.skipped > 0
            ? '已更新 ${result.updated} 个源，${result.skipped} 个本地源无 URL 已跳过'
            : '已更新 ${result.updated} 个源',
      );
    } else {
      flmToast(
        context,
        '已更新 ${result.updated} 个，失败 ${result.failed.length} 个：${result.failed.first}',
      );
    }
  }

  Future<void> _delete(
    BuildContext context,
    SourceState state,
    CustomSourceInfo source,
  ) async {
    final confirmed = await flmConfirmDialog(
      context,
      title: '删除自定义源',
      message: '确定要删除「${source.name}」吗？',
      confirmLabel: '删除',
      danger: true,
    );
    if (!confirmed) return;
    if (!context.mounted) return;
    await state.deleteSource(source.id);
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.source,
    required this.active,
    required this.onTap,
    required this.onDelete,
    this.onUpdate,
  });

  final CustomSourceInfo source;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback? onUpdate;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (source.version.isNotEmpty) 'v${source.version}',
      if (source.author.isNotEmpty) source.author,
      if (source.createdAt > 0) _date(source.createdAt),
      if (source.importUrl != null) '在线源' else '本地导入',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Pressable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
          decoration: BoxDecoration(
            color: active ? accentSoftColor(context) : surfaceFor(context),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: active ? accentBorderColor(context) : lineColor(context),
            ),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: surfaceHighFor(context),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  CupertinoIcons.capsule,
                  size: 20,
                  color: active ? accentFor(context) : mutedFor(context),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      source.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: active ? accentFor(context) : textFor(context),
                      ),
                    ),
                    if (parts.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        parts.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10.5, color: mutedFor(context)),
                      ),
                    ],
                  ],
                ),
              ),
              if (active)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(CupertinoIcons.checkmark_circle_fill, size: 18, color: accentFor(context)),
                ),
              if (onUpdate != null)
                IconButton(
                  onPressed: onUpdate,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(CupertinoIcons.arrow_clockwise, size: 18, color: mutedFor(context)),
                ),
              IconButton(
                onPressed: onDelete,
                visualDensity: VisualDensity.compact,
                icon: Icon(CupertinoIcons.trash, size: 18, color: mutedFor(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _date(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}

class _NoSourceRow extends StatelessWidget {
  const _NoSourceRow({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: surfaceFor(context),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: lineColor(context)),
        ),
        child: Row(
          children: <Widget>[
            Icon(CupertinoIcons.exclamationmark_shield_fill, size: 20, color: mutedFor(context)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '不使用自定义源',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textFor(context),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '仍然可以浏览搜索、歌单、排行榜和歌词',
                    style: TextStyle(fontSize: 10.5, color: mutedFor(context)),
                  ),
                ],
              ),
            ),
            if (active) Icon(CupertinoIcons.check_mark, color: accentFor(context)),
          ],
        ),
      ),
    );
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
    final isDark = auroraIsDark(context);

    Color foreground;
    String title;
    String message;
    IconData icon;

    if (active == null) {
      foreground = goldFor(context);
      title = '未启用自定义源';
      message = '搜索和歌单可以正常浏览，但在线播放需要先启用一个音源脚本。';
      icon = CupertinoIcons.circle;
    } else if (error != null) {
      foreground = coralFor(context);
      title = '${active.name} 初始化失败';
      message = error;
      icon = CupertinoIcons.exclamationmark_shield_fill;
    } else if (state.loading) {
      foreground = accentFor(context);
      title = '${active.name} 初始化中';
      message = '正在加载脚本并读取支持的音乐平台…';
      icon = CupertinoIcons.clock;
    } else if (capabilities.isEmpty) {
      foreground = coralFor(context);
      title = '${active.name} 尚未就绪';
      message = '脚本没有返回可用的音源能力，请检查脚本是否完整。';
      icon = CupertinoIcons.exclamationmark_shield_fill;
    } else {
      foreground = accentFor(context);
      title = '${active.name} 已启用';
      message =
          '可用的平台：${capabilities.sources.keys.map((item) => item.toUpperCase()).join('、')}';
      icon = CupertinoIcons.checkmark_shield_fill;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(kGutter, 8, kGutter, 2),
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: foreground.withValues(alpha: isDark ? 0.10 : 0.08),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: foreground.withValues(alpha: 0.26)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, color: foreground, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: foreground,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
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
                              fontSize: 10,
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
