import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../services/debug_log.dart';
import '../../state/app_state.dart';
import '../kit.dart';

/// Raw request dump for debugging. The display box stays empty until the
/// debug switch in settings is turned on; afterwards every HTTP request made
/// for the source sandboxes (url / headers / body / response) and every
/// source-resolution event is appended here, separated by two blank lines.
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
                              ? '记录中 · ${debug.entries.length} 条（最多保留 200 条）'
                              : '调试开关已关闭，日志为空',
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
                              '打开开关后，这里会实时显示所有请求的\nURL / 头部 / Body / 响应',
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
