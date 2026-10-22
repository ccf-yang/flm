import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../data/custom_source_repository.dart';
import '../../models/custom_source.dart';
import '../../state/player_state.dart';
import '../../state/source_state.dart';
import '../kit.dart';

class CustomSourcesScreen extends StatelessWidget {
  const CustomSourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<SourceState>();
    final activeId = state.active?.id;
    final onlineCount = state.sources
        .where((source) => (source.importUrl ?? '').trim().isNotEmpty)
        .length;
    final manual = state.repository.byGroup(sourceGroupManual);
    final auto = state.repository.byGroup(sourceGroupAuto);
    final web = state.repository.byGroup(sourceGroupWeb);
    final disabled = state.disabledSources;
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
                      icon: CupertinoIcons.slider_horizontal_3,
                      tooltip: '探测设置',
                      onTap: () => _probeSettings(context, state),
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
                      if (state.hubWorking)
                        _HubProgress(state: state)
                      else if (state.loading || state.importing)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: kGutter),
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      _StatusCard(state: state),

                      // ── 手动导入：本地文件 / 自己填的在线 URL ──
                      SectionHead(
                        title: '自定义源',
                        note: _countNote(state, manual),
                        trailing: <Widget>[
                          _HeadPill(
                            label: '导入',
                            icon: CupertinoIcons.plus,
                            onTap: () => _showImportMenu(context, state),
                          ),
                        ],
                      ),
                      ..._rows(context, state, manual, activeId),
                      if (manual.isEmpty)
                        const _GroupHint(
                          '手动导入的脚本永远不被批量操作覆盖：本地 .js 或自己填写的在线直链。',
                        ),

                      // ── 自动导入源：本机实测通过的批量结果 ──
                      SectionHead(
                        title: '自动导入源',
                        note: _countNote(state, auto),
                        trailing: <Widget>[
                          _HeadPill(
                            label: '一键探测',
                            icon: CupertinoIcons.dot_radiowaves_left_right,
                            busy: state.hubWorking,
                            onTap: () => _runHub(
                              context,
                              state,
                              group: sourceGroupAuto,
                              selfProbe: true,
                            ),
                          ),
                          if (auto.isNotEmpty)
                            _HeadPill(
                              label: '清空',
                              icon: CupertinoIcons.trash,
                              danger: true,
                              onTap: () =>
                                  _clearGroup(context, state, sourceGroupAuto),
                            ),
                        ],
                      ),
                      ..._rows(context, state, auto, activeId),
                      if (auto.isEmpty)
                        const _GroupHint(
                          '一键探测会抓取 lx-hub 收录的脚本，在本机逐个实测取链，'
                          '只把能返回真实音频的写进这里，并覆盖本分组。',
                        ),

                      // ── web探测导入源：直接采用 web 每日实测结果 ──
                      SectionHead(
                        title: 'web探测导入源',
                        note: _countNote(state, web),
                        trailing: <Widget>[
                          _HeadPill(
                            label: 'web 获取',
                            icon: CupertinoIcons.down_arrow,
                            busy: state.hubWorking,
                            onTap: () => _runHub(
                              context,
                              state,
                              group: sourceGroupWeb,
                              selfProbe: false,
                            ),
                          ),
                          if (web.isNotEmpty)
                            _HeadPill(
                              label: '清空',
                              icon: CupertinoIcons.trash,
                              danger: true,
                              onTap: () =>
                                  _clearGroup(context, state, sourceGroupWeb),
                            ),
                        ],
                      ),
                      ..._rows(context, state, web, activeId),
                      if (web.isEmpty)
                        const _GroupHint(
                          '从 zlyon.github.io/lx-hub 的每日实测清单批量导入 web 判定可用的源，'
                          '获取后覆盖本分组。',
                        ),
                      // The web list is only as fresh as the hub's last daily
                      // scan, so this is the way to re-test a whole group without
                      // pressing 探测 on every row by hand. It sits under the rows
                      // rather than in the header: that row already carries the
                      // two actions the group needs at a glance.
                      if (web.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(kGutter, 10, kGutter, 0),
                          child: AuroraButton(
                            label: state.hubWorking
                                ? '正在探测…'
                                : '全部探测这 ${web.length} 个源',
                            icon: CupertinoIcons.dot_radiowaves_left_right,
                            secondary: true,
                            expand: true,
                            onTap: state.hubWorking
                                ? null
                                : () => _probeGroup(context, state, sourceGroupWeb),
                          ),
                        ),
                      if (web.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(kGutter, 8, kGutter, 0),
                          child: GestureDetector(
                            onTap: () => _probeSettings(context, state),
                            child: Text(
                              '${_probePlanText(state)} · 点此调整',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: faintFor(context),
                                decoration: TextDecoration.underline,
                                decorationColor: faintFor(context),
                              ),
                            ),
                          ),
                        ),

                      // ── 一键清理：探测判定为死的源，跨所有分组 ──
                      if (disabled.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(kGutter, 22, kGutter, 0),
                          child: AuroraButton(
                            label: '删除全部禁用源（${disabled.length} 个）',
                            icon: CupertinoIcons.trash,
                            secondary: true,
                            expand: true,
                            onTap: () => _deleteDisabled(context, state),
                          ),
                        ),

                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: kGutter),
                        child: _NoSourceRow(
                          active: activeId == null,
                          onTap: () => state.setActive(null),
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
                          'flm 不内置任何音源，也不对脚本内容负责。批量分组（自动导入源 / '
                          'web探测导入源）每次获取都会整组替换，手动导入的自定义源不受影响。',
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

  /// `3 个` / `3 个（禁用 1）` / `空`
  String _countNote(SourceState state, List<CustomSourceInfo> group) {
    if (group.isEmpty) return '空';
    final disabled = group.where((source) => source.disabled).length;
    return disabled == 0
        ? '${group.length} 个'
        : '${group.length} 个（禁用 $disabled）';
  }

  List<Widget> _rows(
    BuildContext context,
    SourceState state,
    List<CustomSourceInfo> group,
    String? activeId,
  ) {
    return group.map((source) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: kGutter),
        child: _SourceRow(
          source: source,
          active: source.id == activeId,
          onTap: () => _activate(context, state, source),
          onUpdate: source.importUrl == null
              ? null
              : () => _updateFromUrl(context, state, source),
          onProbe: () => _probe(context, state, source),
          onToggleDisabled: () => _toggleDisabled(context, state, source),
          onDelete: () => _delete(context, state, source),
        ),
      );
    }).toList(growable: false);
  }

  /// One-tap batch fetch for a group. [selfProbe] marks the difference between
  /// the two entry points: 自动导入源 re-tests every candidate inside this app,
  /// web探测导入源 takes the hub's own daily verdict at face value.
  Future<void> _runHub(
    BuildContext context,
    SourceState state, {
    required String group,
    required bool selfProbe,
  }) async {
    if (state.hubWorking) {
      flmToast(context, '正在获取源，请稍候');
      return;
    }
    if (state.sources.length >= CustomSourceRepository.maxSources &&
        state.repository.byGroup(group).isEmpty) {
      flmToast(context, '自定义源已达 ${CustomSourceRepository.maxSources} 个上限，先删一些');
      return;
    }

    final outcome = await state.scanHubSources(group: group, selfProbe: selfProbe);
    if (!context.mounted) return;
    if (outcome.error != null && outcome.candidates.isEmpty) {
      flmToast(context, '获取失败：${outcome.error}');
      return;
    }
    if (!outcome.hasUsable) {
      final first = outcome.dead.isEmpty ? '' : '\n${outcome.dead.first.detail}';
      await flmConfirmDialog(
        context,
        title: '没有可用的源',
        message: outcome.candidates.isEmpty
            ? (outcome.error ?? '列表里没有可导入的脚本')
            : '共获取 ${outcome.candidates.length} 个脚本，'
                '${selfProbe ? '本机实测全部取链失败' : 'web 侧没有可用平台判定'}。$first',
        cancelLabel: '关闭',
        confirmLabel: '知道了',
      );
      return;
    }
    await _reviewHubImport(context, state, outcome);
  }

  /// Show what passed, then only overwrite the group if the user agrees.
  Future<void> _reviewHubImport(
    BuildContext context,
    SourceState state,
    HubImportOutcome outcome,
  ) async {
    final existing = state.repository.byGroup(outcome.group).length;
    final groupName = sourceGroupName(outcome.group);
    final approved = await showFlmSheet<bool>(
      context,
      title: '可用源 · $groupName',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              children: <Widget>[
                Text(
                  '${_stamp(outcome.generatedAt)}｜列表 ${outcome.poolSize} 个，'
                  '本次检测 ${outcome.candidates.length} 个，可用 ${outcome.usable.length} 个'
                  '${outcome.cancelled ? '（已手动停止）' : ''}。\n'
                  '确认后会${existing > 0 ? '用这 ${outcome.seeds.length} 个源覆盖当前 $existing 个' : '写入这 ${outcome.seeds.length} 个源'}，'
                  '手动导入的自定义源不受影响。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.6,
                    color: mutedFor(context),
                  ),
                ),
                const SizedBox(height: 12),
                ...outcome.usable.map(
                  (item) => _VerdictRow(
                    name: item.entry.name,
                    detail: item.detail,
                    ok: true,
                    extra: item.entry.author.isEmpty ? null : item.entry.author,
                  ),
                ),
                if (outcome.dead.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    '未通过 ${outcome.dead.length} 个',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: faintFor(context),
                    ),
                  ),
                  const SizedBox(height: 4),
                  ...outcome.dead.take(12).map(
                        (item) => _VerdictRow(
                          name: item.entry.name,
                          detail: item.detail,
                          ok: false,
                        ),
                      ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
            child: AuroraButton(
              label: existing > 0
                  ? '覆盖导入 ${outcome.seeds.length} 个源'
                  : '导入 ${outcome.seeds.length} 个源',
              icon: CupertinoIcons.square_arrow_down,
              expand: true,
              onTap: () => Navigator.pop(context, true),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: AuroraButton(
              label: '取消',
              secondary: true,
              expand: true,
              onTap: () => Navigator.pop(context, false),
            ),
          ),
        ],
      ),
    );
    if (approved != true) return;
    if (!context.mounted) return;

    final count = await state.applyHubGroup(outcome.group, outcome.seeds);
    if (!context.mounted) return;
    flmToast(
      context,
      count == 0
          ? '写入失败：脚本没有通过校验'
          : '已写入 $count 个源到「$groupName」',
    );
  }

  Future<void> _clearGroup(
    BuildContext context,
    SourceState state,
    String group,
  ) async {
    final count = state.repository.byGroup(group).length;
    final confirmed = await flmConfirmDialog(
      context,
      title: '清空${sourceGroupName(group)}',
      message: '删除这 $count 个源及其脚本？手动导入的自定义源不受影响。',
      confirmLabel: '清空',
      danger: true,
    );
    if (!confirmed) return;
    if (!context.mounted) return;
    final removed = await state.clearHubGroup(group);
    if (!context.mounted) return;
    flmToast(context, '已清空 $removed 个源');
  }

  /// Probe every source of [group] the way the user would by tapping 探测 on each
  /// row, and switch the ones that cannot serve audio off automatically.
  Future<void> _probeGroup(
    BuildContext context,
    SourceState state,
    String group,
  ) async {
    if (state.hubWorking) {
      flmToast(context, '正在检测源，请稍候');
      return;
    }
    final count = state.repository.byGroup(group).length;
    if (count == 0) return;
    final confirmed = await flmConfirmDialog(
      context,
      title: '全部探测｜${sourceGroupName(group)}',
      message: '挂载脚本并实测取链，和手动一行行点探测一样；'
          '取不到真实音频的源会被自动禁用，不再参与播放。'
          '拿不到测试歌曲的源保持原样，中途也可以点停止。\n'
          '本次：${_probePlanText(state)}，可在右上角滑杆图标里调整。',
      cancelLabel: '取消',
      confirmLabel: '开始探测 $count 个',
    );
    if (!confirmed) return;
    if (!context.mounted) return;

    final outcome = await state.probeGroup(group);
    if (!context.mounted) return;
    if (outcome.error != null) {
      flmToast(context, outcome.error!);
      return;
    }
    await _showGroupProbeResult(context, outcome);
  }

  /// How the next 一键探测 / 全部探测 will run, in one line.
  String _probePlanText(SourceState state) {
    final workers = state.probeConcurrency;
    return '${workers > 1 ? '$workers 路并发' : '逐个探测'} · '
        '每个源 ${state.probeTimeoutSeconds}s 上限';
  }

  /// 批量探测的超时与并发数.
  ///
  /// A batch reads both when it starts, so nothing here disturbs a run that is
  /// already going — the sliders are about the next press, and the sheet says so.
  Future<void> _probeSettings(BuildContext context, SourceState state) async {
    final appState = state.appState;
    await showFlmSheet<void>(
      context,
      title: '探测速度',
      child: StatefulBuilder(
        builder: (sheetContext, rebuild) {
          final timeout = appState.settings.probeTimeoutClamped;
          final workers = appState.settings.probeConcurrencyClamped;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '下一次「一键探测 / 全部探测」生效，正在跑的那批不受影响。',
                  style: TextStyle(fontSize: 11, color: mutedFor(context)),
                ),
                const SizedBox(height: 14),
                _ProbeSettingRow(
                  title: '单个源超时',
                  value: '${timeout}s',
                  hint: timeout <= 12
                      ? '很激进：反应慢的脚本会被判成「未判定」，不会被禁用，但也不会导入。'
                      : timeout >= 60
                          ? '很慢很稳：适合网络差、脚本反应迟的场合，整批耗时会拉长。'
                          : '一个源最多花这么久；到点没结果的算「未判定」，保持原样。',
                  slider: Slider(
                    value: timeout.toDouble(),
                    min: 8,
                    max: 90,
                    divisions: 41,
                    label: '$timeout',
                    activeColor: accentFor(context),
                    onChanged: (next) {
                      appState.update(
                        (item) => item.probeTimeoutSeconds = next.round(),
                      );
                      rebuild(() {});
                    },
                  ),
                ),
                const SizedBox(height: 6),
                _ProbeSettingRow(
                  title: '同时探测几个源',
                  value: '$workers 路',
                  hint: workers == 1
                      ? '一次只测一个：最省内存，也最慢。'
                      : workers >= 5
                          ? '每个并发都会开一个脚本沙箱，手机发烫或内存紧张就调低。'
                          : '并发越高整批越快，代价是同时运行多个脚本沙箱。',
                  slider: Slider(
                    value: workers.toDouble(),
                    min: 1,
                    max: 6,
                    divisions: 5,
                    label: '$workers',
                    activeColor: accentFor(context),
                    onChanged: (next) {
                      appState.update(
                        (item) => item.probeConcurrency = next.round(),
                      );
                      rebuild(() {});
                    },
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '参考：30 个源、3 路并发、每个 20s，通常两三分钟跑完；'
                  '调到 6 路并发约能快一半。',
                  style: TextStyle(fontSize: 10.5, height: 1.6, color: faintFor(context)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// The verdict list of a batch probe: what was switched off, what answered,
  /// and what could not be judged at all.
  Future<void> _showGroupProbeResult(
    BuildContext context,
    GroupProbeOutcome outcome,
  ) async {
    await showFlmSheet<void>(
      context,
      title: '探测结果 · ${sourceGroupName(outcome.group)}',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              children: <Widget>[
                Text(
                  '共检测 ${outcome.reports.length} 个源，'
                  '可用 ${outcome.usable.length} 个，'
                  '已自动禁用 ${outcome.disabled.length} 个'
                  '${outcome.skipped.isEmpty ? '' : '，未判定 ${outcome.skipped.length} 个'}'
                  '${outcome.cancelled ? '（已手动停止）' : ''}。\n'
                  '被禁用的源还在列表里，可以随时用页面底部的「删除全部禁用源」清掉。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.6,
                    color: mutedFor(context),
                  ),
                ),
                const SizedBox(height: 12),
                if (outcome.disabled.isNotEmpty) ...<Widget>[
                  ...outcome.disabled.map(
                    (report) => _VerdictRow(
                      name: report.name,
                      detail: report.detail,
                      ok: false,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (outcome.usable.isNotEmpty) ...<Widget>[
                  Text(
                    '可用 ${outcome.usable.length} 个',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: faintFor(context),
                    ),
                  ),
                  const SizedBox(height: 4),
                  ...outcome.usable.map(
                    (report) => _VerdictRow(
                      name: report.name,
                      detail: report.detail,
                      ok: true,
                    ),
                  ),
                ],
                if (outcome.skipped.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  ...outcome.skipped.map(
                    (report) => _VerdictRow(
                      name: report.name,
                      detail: report.detail,
                      ok: false,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
            child: AuroraButton(
              label: '知道了',
              secondary: true,
              expand: true,
              onTap: () => Navigator.pop(context),
            ),
          ),
        ],
      ),
    );
  }

  /// Drop every source a probe has switched off, across all three groups. The
  /// confirmation names them, because deleting also removes the saved script and
  /// its refresh URL.
  Future<void> _deleteDisabled(BuildContext context, SourceState state) async {
    final targets = state.disabledSources;
    if (targets.isEmpty) return;
    final names = targets.map((source) => source.name).toList();
    final shown = names.take(6).join('、');
    final confirmed = await flmConfirmDialog(
      context,
      title: '删除全部禁用源',
      message: '删除这 ${targets.length} 个已禁用的源及其脚本？\n'
          '$shown${names.length > 6 ? ' 等' : ''}\n'
          '启用中的源不会被删除，源页的手动导入也不会受影响。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!confirmed) return;
    if (!context.mounted) return;
    final removed = await state.deleteDisabledSources();
    if (!context.mounted) return;
    flmToast(context, '已删除 $removed 个禁用源');
  }

  String _stamp(DateTime? time) {
    if (time == null) return '列表时间未知';
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
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
    if (source.disabled) {
      flmToast(context, '「${source.name}」已禁用，先点电源按钮启用');
      return;
    }
    await state.setActive(source);
    if (!context.mounted) return;
    flmToast(context, '已选择「${source.name}」');
  }

  Future<void> _toggleDisabled(
    BuildContext context,
    SourceState state,
    CustomSourceInfo source,
  ) async {
    await state.setDisabled(source, !source.disabled);
    if (!context.mounted) return;
    flmToast(
      context,
      source.disabled
          ? '已启用「${source.name}」'
          : '已禁用「${source.name}」，取链时不再等它',
    );
  }

  /// Resolve the song that is currently playing through this one source only,
  /// then report whether the link it returns actually serves audio.
  Future<void> _probe(
    BuildContext context,
    SourceState state,
    CustomSourceInfo source,
  ) async {
    final song = context.read<PlayerController>().current;
    flmToast(context, '正在探测「${source.name}」…');
    final report = await state.probeSource(source, song: song);
    if (!context.mounted) return;
    final act = await flmConfirmDialog(
      context,
      title: '${report.ok ? '探测通过' : '探测失败'}｜${source.name}',
      message: '${report.headline}\n${report.detail}',
      cancelLabel: '知道了',
      confirmLabel: report.ok ? '启用这个源' : '禁用这个源',
      danger: !report.ok,
    );
    if (!act) return;
    await state.setDisabled(source, !report.ok);
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
    required this.onProbe,
    required this.onToggleDisabled,
    this.onUpdate,
  });

  final CustomSourceInfo source;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onProbe;
  final VoidCallback onToggleDisabled;
  final VoidCallback? onUpdate;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (source.disabled) '已禁用',
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
                        color: active
                            ? accentFor(context)
                            : (source.disabled ? mutedFor(context) : textFor(context)),
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
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(CupertinoIcons.checkmark_circle_fill,
                      size: 17, color: accentFor(context)),
                ),
              _RowIcon(
                icon: CupertinoIcons.dot_radiowaves_left_right,
                color: mutedFor(context),
                onTap: onProbe,
              ),
              _RowIcon(
                icon: source.disabled
                    ? CupertinoIcons.play_circle
                    : CupertinoIcons.power,
                color: source.disabled ? goldFor(context) : mutedFor(context),
                onTap: onToggleDisabled,
              ),
              if (onUpdate != null)
                _RowIcon(
                  icon: CupertinoIcons.arrow_clockwise,
                  color: mutedFor(context),
                  onTap: onUpdate,
                ),
              _RowIcon(
                icon: CupertinoIcons.trash,
                color: mutedFor(context),
                onTap: onDelete,
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

/// Compact trailing action button for a source row.
class _RowIcon extends StatelessWidget {
  const _RowIcon({required this.icon, required this.color, required this.onTap});

  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      icon: Icon(icon, size: 17, color: color),
    );
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

/// Banner shown while a batch fetch runs: which candidate is being handled, how
/// far the scan got, and a stop button (each candidate can take some seconds).
class _HubProgress extends StatelessWidget {
  const _HubProgress({required this.state});

  final SourceState state;

  @override
  Widget build(BuildContext context) {
    final text = state.hubTotal > 0
        ? '${state.hubStatus}（${state.hubDone}/${state.hubTotal}）'
        : state.hubStatus;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kGutter, 10, kGutter, 2),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: BoxDecoration(
          color: surfaceFor(context),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: lineColor(context)),
        ),
        child: Row(
          children: <Widget>[
            const SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                text.isEmpty ? '正在获取源…' : text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, height: 1.4, color: mutedFor(context)),
              ),
            ),
            _HeadPill(
              label: '停止',
              icon: CupertinoIcons.stop_fill,
              danger: true,
              onTap: state.cancelHubScan,
            ),
          ],
        ),
      ),
    );
  }
}

/// Small pill on a group header row (一键探测 / 清空 / 导入).
class _HeadPill extends StatelessWidget {
  const _HeadPill({
    required this.label,
    this.icon,
    required this.onTap,
    this.danger = false,
    this.busy = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool danger;

  /// Another batch is running, so this entry point is temporarily inert.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = !busy;
    final color = !enabled
        ? faintFor(context)
        : (danger ? coralFor(context) : accentFor(context));
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Pressable(
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: enabled ? color.withValues(alpha: 0.35) : lineColor(context),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 11.5, color: color),
                const SizedBox(width: 3),
              ],
              Text(
                label,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One-line explanation shown under an empty group, instead of a big empty card.
class _GroupHint extends StatelessWidget {
  const _GroupHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(kGutter, 2, kGutter, 4),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, height: 1.55, color: faintFor(context)),
      ),
    );
  }
}

/// One row of the 探测速度 sheet: what the setting is called, what it is set to,
/// the slider, and — the part that actually decides it — what this value costs.
class _ProbeSettingRow extends StatelessWidget {
  const _ProbeSettingRow({
    required this.title,
    required this.value,
    required this.hint,
    required this.slider,
  });

  final String title;
  final String value;
  final String hint;
  final Widget slider;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: textFor(context),
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: accentFor(context),
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        slider,
        Text(
          hint,
          style: TextStyle(fontSize: 10.5, height: 1.5, color: faintFor(context)),
        ),
      ],
    );
  }
}

/// One script inside the post-scan review sheet.
class _VerdictRow extends StatelessWidget {
  const _VerdictRow({
    required this.name,
    required this.detail,
    required this.ok,
    this.extra,
  });

  final String name;
  final String detail;
  final bool ok;
  final String? extra;

  @override
  Widget build(BuildContext context) {
    final color = ok ? accentFor(context) : faintFor(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              ok ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
              size: 14,
              color: color,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  extra == null || extra!.isEmpty ? name : '$name · $extra',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: ok ? textFor(context) : mutedFor(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, height: 1.45, color: faintFor(context)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
