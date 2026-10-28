import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../services/debug_log.dart';
import '../../state/app_state.dart';
import '../kit.dart';

/// What the player did, newest last, for handing to the developer.
///
/// Every line is a playback decision: a skip from the lock screen / headset / car
/// head unit, a link resolve and why it stopped, a boundary promotion, a watchdog
/// re-arm, plus the source batch pipeline. The old HTTP url/headers/body dump is
/// gone. The log is also written to `Documents/Debug/playback.log`, so the run
/// that stalled *before* the app was killed can still be copied out here — the
/// previous session's tail is read back at startup.
class DebugScreen extends StatelessWidget {
  const DebugScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final debug = context.watch<DebugLog>();
    final text = debug.text;
    final empty = text.isEmpty;

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
                  title: '调试日志',
                  trailing: <Widget>[
                    if (!empty) ...<Widget>[
                      IconBtn(
                        icon: CupertinoIcons.doc_on_clipboard,
                        tooltip: '复制全部',
                        onTap: () async {
                          await Clipboard.setData(ClipboardData(text: text));
                          if (!context.mounted) return;
                          flmToast(context, '已复制 ${debug.entries.length} 条');
                        },
                      ),
                      const SizedBox(width: 8),
                      IconBtn(
                        icon: CupertinoIcons.trash,
                        tooltip: '清空',
                        onTap: debug.clear,
                      ),
                    ],
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(kGutter, 4, kGutter, 8),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          debug.enabled
                              ? '记录中 · ${debug.entries.length} 条（最多 ${debug.maxEntries} 条，同时写入本机文件，关掉只暂停不清空）'
                              : '记录已暂停 · 历史日志保留，点右上角垃圾桶可清空',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: debug.enabled ? accentFor(context) : mutedFor(context),
                          ),
                        ),
                      ),
                      CupertinoSwitch(
                        value: debug.enabled,
                        activeTrackColor: accentStrongFor(context),
                        onChanged: (value) {
                          context.read<AppState>().update(
                            (settings) => settings.debugEnabled = value,
                          );
                          debug.setEnabled(value);
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(kGutter, 0, kGutter, 24),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: panelFor(context),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: lineColor(context)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: empty
                        ? Center(
                            child: Text(
                              '这里逐条记录后台播放与切歌的经过：\n'
                              '远程命令、取链到哪一步、边界换曲、\n'
                              '静音看门狗做了什么\n'
                              '（日志同时存本机文件，重启后还能看到上一次）',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.8,
                                color: faintFor(context),
                              ),
                            ),
                          )
                        : SelectionArea(
                            child: SingleChildScrollView(
                              reverse: true,
                              child: Text(
                                text,
                                style: TextStyle(
                                  fontFamilyFallback: const <String>[
                                    'Menlo',
                                    'Courier',
                                    'monospace',
                                  ],
                                  fontSize: 10.5,
                                  height: 1.55,
                                  color: textFor(context),
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
