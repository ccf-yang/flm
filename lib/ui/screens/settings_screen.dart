import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../models/app_settings.dart';
import '../../services/backup_service.dart';
import '../../services/debug_log.dart';
import '../../state/app_state.dart';
import '../../state/library_state.dart';
import '../../state/player_state.dart';
import '../../state/source_state.dart';
import '../kit.dart';
import '../widgets/source_chips.dart';
import 'custom_sources_screen.dart';
import 'debug_screen.dart';

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
                  title: '设置',
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(kGutter, 4, kGutter, 40),
                    children: <Widget>[
                      _IntroCard(),
                      const SectionHead(title: '外观'),
                      _Group(
                        children: <Widget>[
                          _SettingRow(
                            icon: auroraIsDark(context)
                                ? CupertinoIcons.moon
                                : CupertinoIcons.sun_max,
                            label: '主题模式',
                            value: _themeLabel(settings.themeMode),
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
                          _SettingRow(
                            icon: CupertinoIcons.square,
                            label: '挂件形状',
                            caption: '悬浮播放入口的轮廓',
                            value: _shapeLabel(settings.miniPlayerShape),
                            onTap: () => _pickOption(
                              context,
                              title: '挂件形状',
                              current: settings.miniPlayerShape,
                              options: const <Map<String, String>>[
                                <String, String>{'id': 'circle', 'name': '圆形'},
                                <String, String>{'id': 'rect', 'name': '方形'},
                              ],
                              onSelected: (value) => appState.update(
                                (item) => item.miniPlayerShape = value,
                              ),
                            ),
                          ),
                          _SwitchRow(
                            icon: CupertinoIcons.photo,
                            label: '跟随封面配色',
                            caption: '开启时取当前封面的主色调，关闭则用下面的中心配色',
                            value: settings.miniPlayerUseImageColor,
                            onChanged: (value) {
                              appState.update(
                                (item) => item.miniPlayerUseImageColor = value,
                              );
                            },
                          ),
                          _SettingRow(
                            icon: CupertinoIcons.paintbrush_fill,
                            label: '中心配色',
                            caption: '封面底板与进度环颜色',
                            trailing: _colorDot(settings.miniPlayerColor),
                            onTap: () => _pickMiniColor(context, appState),
                          ),
                          _SettingRow(
                            icon: CupertinoIcons.drop,
                            label: '挂件透明度',
                            value: '${(settings.miniPlayerOpacity * 100).round()}%',
                            onTap: () => _pickMiniOpacity(context, appState),
                          ),
                        ],
                      ),
                      const SectionHead(title: '音乐平台'),
                      _Group(
                        children: <Widget>[
                          _SwitchRow(
                            icon: CupertinoIcons.line_horizontal_3_decrease,
                            label: '显示平台筛选',
                            caption: '搜索、歌单和榜单顶部的平台切换条；关闭后搜索改用聚合源',
                            value: settings.showPlatformFilter,
                            onChanged: (value) {
                              appState.update((item) => item.showPlatformFilter = value);
                            },
                          ),
                          _SettingRow(
                            icon: CupertinoIcons.square_grid_2x2,
                            label: '平台分类',
                            value: _platformSummary(settings),
                            caption: '只留你真正会用的平台，只剩一个时切换条自动隐藏',
                            onTap: () => _pickPlatforms(context, appState),
                          ),
                        ],
                      ),
                      const SectionHead(title: '播放'),
                      _Group(
                        children: <Widget>[
                          _SettingRow(
                            icon: CupertinoIcons.waveform,
                            label: '优先音质',
                            value: _qualityLabel(settings.quality),
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
                          _SettingRow(
                            icon: CupertinoIcons.repeat,
                            label: '播放模式',
                            value: playMode.label,
                            onTap: () {
                              _pickOption(
                                context,
                                title: '播放模式',
                                current: playMode.name,
                                options: PlayMode.values
                                    .map((mode) =>
                                        <String, String>{'id': mode.name, 'name': mode.label})
                                    .toList(),
                                onSelected: (value) {
                                  final mode =
                                      PlayMode.values.firstWhere((item) => item.name == value);
                                  context.read<PlayerController>().setPlayMode(mode);
                                },
                              );
                            },
                          ),
                          _SwitchRow(
                            icon: CupertinoIcons.clock,
                            label: '记住播放进度',
                            caption: '下次打开应用时恢复上次播放的歌曲和位置',
                            value: settings.saveProgress,
                            onChanged: (value) {
                              appState.update((settings) => settings.saveProgress = value);
                            },
                          ),
                          _SwitchRow(
                            icon: CupertinoIcons.play_arrow,
                            label: '启动后自动播放',
                            caption: '恢复上次播放时立即开始播放',
                            value: settings.autoPlayOnStart,
                            onChanged: (value) {
                              appState.update((settings) => settings.autoPlayOnStart = value);
                            },
                          ),
                          _SwitchRow(
                            icon: CupertinoIcons.text_quote,
                            label: '显示歌词翻译',
                            caption: '如果歌词提供翻译，会在原文下方显示',
                            value: settings.showTranslation,
                            onChanged: (value) {
                              appState.update((settings) => settings.showTranslation = value);
                              context.read<PlayerController>().reloadLyrics();
                            },
                          ),
                          _SettingRow(
                            icon: CupertinoIcons.xmark_circle_fill,
                            label: '不喜欢规则',
                            value: '${settings.dislikedKeys.length} 条',
                            trailing: settings.dislikedKeys.isEmpty
                                ? null
                                : Pressable(
                                    onTap: () {
                                      appState.clearDislikes();
                                      flmToast(context, '已清空不喜欢规则');
                                    },
                                    child: Text(
                                      '清空',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: coralFor(context),
                                      ),
                                    ),
                                  ),
                            onTap: settings.dislikedKeys.isEmpty
                                ? null
                                : () {
                                    appState.clearDislikes();
                                    flmToast(context, '已清空不喜欢规则');
                                  },
                          ),
                        ],
                      ),
                      const SectionHead(title: '数据'),
                      _Group(
                        children: <Widget>[
                          _SettingRow(
                            icon: CupertinoIcons.folder,
                            label: '导入本地音乐',
                            onTap: () => _importLocal(context, library),
                          ),
                          _SettingRow(
                            icon: CupertinoIcons.square_arrow_up,
                            label: '导出备份',
                            caption: '列表 + 自定义源（含 URL/脚本）+ 设置',
                            onTap: () => _exportBackup(context, context.read<BackupService>()),
                          ),
                          _SettingRow(
                            icon: CupertinoIcons.square_arrow_down,
                            label: '导入备份',
                            caption: '恢复列表、自定义源和设置',
                            onTap: () => _importBackup(context, context.read<BackupService>()),
                          ),
                        ],
                      ),
                      const SectionHead(title: '音源'),
                      _Group(
                        children: <Widget>[
                          _SettingRow(
                            icon: CupertinoIcons.capsule,
                            label: '自定义源',
                            caption: _sourceSubtitle(sourceState),
                            onTap: () {
                              Navigator.of(context).push(
                                CupertinoPageRoute<void>(
                                  builder: (_) => const CustomSourcesScreen(),
                                ),
                              );
                            },
                          ),
                          _SettingRow(
                            icon: CupertinoIcons.wrench,
                            label: '调试',
                            caption: settings.debugEnabled
                                ? '请求记录开启中 · 点击查看日志'
                                : '记录所有请求的 URL / 头部 / Body，便于排查',
                            trailing: IgnorePointer(
                              child: CupertinoSwitch(
                                value: settings.debugEnabled,
                                activeTrackColor: accentStrongFor(context),
                                onChanged: null,
                              ),
                            ),
                            onTap: () {
                              if (!settings.debugEnabled) {
                                // First tap arms the recorder; from then on the
                                // row just opens the log page.
                                appState.update(
                                  (settings) => settings.debugEnabled = true,
                                );
                                context.read<DebugLog>().setEnabled(true);
                              }
                              Navigator.of(context).push(
                                CupertinoPageRoute<void>(
                                  builder: (_) => const DebugScreen(),
                                ),
                              );
                            },
                          ),
                        ],
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

  String _shapeLabel(String shape) {
    switch (shape) {
      case 'rect':
        return '方形';
      default:
        return '圆形';
    }
  }

  Widget _colorDot(String id) {
    final color = Color(AppSettings.miniPlayerColorValue(id));
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: color.withValues(alpha: 0.4), width: 3),
      ),
    );
  }

  static const Map<String, String> _colorNames = <String, String>{
    'mint': '薄荷',
    'coral': '珊瑚',
    'gold': '琥珀',
    'sky': '天蓝',
    'violet': '紫罗兰',
    'snow': '月白',
  };

  Future<void> _pickMiniColor(BuildContext context, AppState appState) async {
    final current = appState.settings.miniPlayerColor;
    await showFlmSheet<void>(
      context,
      title: '中心配色',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
        child: Wrap(
          spacing: 18,
          runSpacing: 16,
          alignment: WrapAlignment.center,
          children: AppSettings.kMiniPlayerColors.entries.map((entry) {
            final color = Color(entry.value);
            final selected = entry.key == current;
            return Pressable(
              onTap: () {
                appState.update((item) => item.miniPlayerColor = entry.key);
                Navigator.pop(context);
              },
              child: SizedBox(
                width: 52,
                child: Column(
                  children: <Widget>[
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color,
                        boxShadow: <BoxShadow>[
                          if (selected)
                            BoxShadow(
                              color: color.withValues(alpha: 0.55),
                              blurRadius: 14,
                              spreadRadius: 2,
                            ),
                        ],
                        border: Border.all(
                          color: selected
                              ? textFor(context)
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      _colorNames[entry.key] ?? entry.key,
                      style: TextStyle(
                        fontSize: 10,
                        color: selected ? textFor(context) : mutedFor(context),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Future<void> _pickMiniOpacity(BuildContext context, AppState appState) async {
    await showFlmSheet<void>(
      context,
      title: '挂件透明度',
      child: StatefulBuilder(
        builder: (sheetContext, rebuild) {
          final value = appState.settings.miniPlayerOpacity;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '${(value * 100).round()}%',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: textFor(context),
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Slider(
                  value: value.clamp(0.3, 1.0).toDouble(),
                  min: 0.3,
                  max: 1.0,
                  activeColor: accentFor(context),
                  onChanged: (next) {
                    appState.update(
                      (item) => item.miniPlayerOpacity = next,
                    );
                    rebuild(() {});
                  },
                ),
                Text(
                  '越接近 100% 越不透明，方便在不同背景下都看得清。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10.5, color: faintFor(context)),
                ),
              ],
            ),
          );
        },
      ),
    );
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

  String _platformSummary(AppSettings settings) {
    final ids = settings.platformIds;
    if (ids.length == AppSettings.kPlatformIds.length) return '全部平台';
    final names = ids.map((id) {
      final match = kSourceOptions.where((option) => option['id'] == id);
      return match.isEmpty ? id : match.first['name'] ?? id;
    }).join('、');
    return '${ids.length} 项 · $names';
  }

  Future<void> _pickPlatforms(BuildContext context, AppState appState) async {
    final selected = appState.settings.platformIds.toSet();
    await showFlmSheet<void>(
      context,
      title: '平台分类',
      child: StatefulBuilder(
        builder: (sheetContext, rebuildSheet) {
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                  child: Text(
                    '至少保留一个平台。取消勾选后，对应的切换条不会再出现，被隐藏的旧选择会自动改用剩下的平台。',
                    style: TextStyle(fontSize: 11.5, height: 1.5, color: mutedFor(context)),
                  ),
                ),
                ...kSourceOptions.map((option) {
                  final id = option['id'] ?? '';
                  final active = selected.contains(id);
                  return OptionRow(
                    label: option['name'] ?? id,
                    active: active,
                    onTap: () {
                      if (active) {
                        if (selected.length <= 1) {
                          flmToast(context, '至少保留一个平台');
                          return;
                        }
                        selected.remove(id);
                      } else {
                        selected.add(id);
                      }
                      appState.update((item) => item.visibleSources =
                          AppSettings.kPlatformIds.where(selected.contains).toList());
                      rebuildSheet(() {});
                    },
                  );
                }),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _pickOption(
    BuildContext context, {
    required String title,
    required String current,
    required List<Map<String, String>> options,
    required ValueChanged<String> onSelected,
  }) async {
    await showFlmSheet<void>(
      context,
      title: title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ...options.map((option) {
            return OptionRow(
              label: option['name'] ?? '',
              active: option['id'] == current,
              onTap: () {
                Navigator.pop(context);
                onSelected(option['id'] ?? '');
              },
            );
          }),
          const SizedBox(height: 8),
        ],
      ),
    );
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
        await Clipboard.setData(ClipboardData(text: path));
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

class _IntroCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Row(
        children: <Widget>[
          const GradientArt(seed: 'flm-about', radius: 18, width: 56, height: 56, decorate: true),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'flm',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    color: textFor(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '版本 1.0.5 · 安静的光，随处可听',
                  style: TextStyle(fontSize: 11, color: mutedFor(context)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: surfaceFor(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: lineColor(context)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          for (var i = 0; i < children.length; i++) ...<Widget>[
            if (i > 0)
              Divider(height: 1, thickness: 1, indent: 52, color: lineColor(context)),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.label,
    this.value,
    this.caption,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? value;
  final String? caption;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Pressable(
      onTap: onTap,
      child: Opacity(
        opacity: enabled ? 1 : 0.6,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 20, color: accentFor(context)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: textFor(context),
                      ),
                    ),
                    if (caption != null) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        caption!,
                        style: TextStyle(fontSize: 11, height: 1.4, color: mutedFor(context)),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null)
                trailing!
              else ...<Widget>[
                if (value != null)
                  Text(
                    value!,
                    style: TextStyle(fontSize: 12.5, color: mutedFor(context)),
                  ),
                const SizedBox(width: 4),
                Icon(CupertinoIcons.chevron_right, size: 15, color: faintFor(context)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.caption,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 20, color: accentFor(context)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: textFor(context),
                  ),
                ),
                if (caption != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    caption!,
                    style: TextStyle(fontSize: 11, height: 1.4, color: mutedFor(context)),
                  ),
                ],
              ],
            ),
          ),
          CupertinoSwitch(
            value: value,
            activeTrackColor: accentStrongFor(context),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
