import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../models/song.dart';
import '../../state/player_state.dart';
import '../kit.dart';
import 'cover_art.dart';
import 'empty_state.dart';
import 'song_actions_sheet.dart';

/// Row extents are fixed so the current row can be placed exactly in the middle
/// of the viewport during the very first frame. A shrink-wrapped, variable
/// height list cannot do that without a visible flash of the top of the queue.
const double _pastExtent = 56;
const double _nextExtent = 56;
const double _currentExtent = 68;
const double _headerExtent = 32;

enum _Kind { past, current, upcoming, headerNow, headerNext }

class _Entry {
  const _Entry(this.kind, this.queueIndex, this.extent);

  final _Kind kind;
  final int queueIndex;
  final double extent;
}

List<_Entry> _buildEntries(List<Song> queue, int index) {
  final hasCurrent = index >= 0 && index < queue.length;
  final rows = <_Entry>[];
  if (hasCurrent) {
    for (var i = 0; i < index; i += 1) {
      rows.add(_Entry(_Kind.past, i, _pastExtent));
    }
    rows.add(_Entry(_Kind.headerNow, index, _headerExtent));
    rows.add(_Entry(_Kind.current, index, _currentExtent));
    rows.add(_Entry(_Kind.headerNext, index, _headerExtent));
    for (var i = index + 1; i < queue.length; i += 1) {
      rows.add(_Entry(_Kind.upcoming, i, _nextExtent));
    }
  } else {
    for (var i = 0; i < queue.length; i += 1) {
      rows.add(_Entry(_Kind.upcoming, i, _nextExtent));
    }
  }
  return rows;
}

double _offsetOf(List<_Entry> entries, int row) {
  var offset = 0.0;
  for (var i = 0; i < row && i < entries.length; i += 1) {
    offset += entries[i].extent;
  }
  return offset;
}

/// Seconds left in the queue, counting the rows after the current one.
/// `interval` is a source-provided string, so unparseable entries add nothing.
Duration _remainingInQueue(List<Song> queue, int index) {
  if (index < 0 || index >= queue.length) return Duration.zero;
  var seconds = 0;
  for (var i = index + 1; i < queue.length; i += 1) {
    final raw = queue[i].interval.trim();
    if (raw.isEmpty) continue;
    final parts = raw.split(':');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0].trim());
      final s = int.tryParse(parts[1].trim());
      if (m != null && s != null) seconds += m * 60 + s;
    } else {
      seconds += int.tryParse(raw) ?? 0;
    }
  }
  return Duration(seconds: seconds);
}

void showPlayQueueSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x66000000),
    builder: (_) => const _QueueSheet(),
  );
}

class _QueueSheet extends StatefulWidget {
  const _QueueSheet();

  @override
  State<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<_QueueSheet> {
  /// Built during the first layout with the playing row already centred, so the
  /// queue never paints the top of the list and then jumps.
  ScrollController? _controller;

  List<_Entry> _entries = const <_Entry>[];
  int _currentRow = -1;
  double _viewportHeight = 0;
  bool _far = false;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  double get _currentTop =>
      _currentRow < 0 ? 0 : _offsetOf(_entries, _currentRow);

  double _centerOffset() {
    final target = _currentTop - (_viewportHeight - _currentExtent) / 2;
    final controller = _controller;
    if (target < 0) return 0;
    if (controller == null || !controller.hasClients) return target;
    final max = controller.position.maxScrollExtent;
    return target > max ? max : target;
  }

  void _onScroll() {
    final controller = _controller;
    if (controller == null || !controller.hasClients || _currentRow < 0) return;
    final position = controller.position.pixels;
    final top = _currentTop;
    final lost =
        top + _currentExtent < position || top > position + _viewportHeight;
    if (lost != _far) setState(() => _far = lost);
  }

  void _locate() {
    final controller = _controller;
    if (controller == null || !controller.hasClients || _currentRow < 0) return;
    controller.animateTo(
      _centerOffset(),
      duration: const Duration(milliseconds: 340),
      curve: AuroraMotion.ease,
    );
  }

  /// Tracks the row that holds the playing song. It deliberately does not
  /// scroll: when a track ends on its own the list must stay where the user left
  /// it, and the locate pill takes over from there.
  void _track(int currentRow, double viewportHeight) {
    _currentRow = currentRow;
    _viewportHeight = viewportHeight;
  }

  Future<void> _clearQueue(BuildContext context) async {
    final ok = await flmConfirmDialog(
      context,
      title: '清空播放队列',
      message: '当前队列和正在播放的歌曲都会停掉，恢复播放的进度记录也会一起清掉。',
      confirmLabel: '清空',
      danger: true,
    );
    if (!ok || !context.mounted) return;
    final player = context.read<PlayerController>();
    player.clearQueue();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        bottom: true,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.92,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: panelFor(context),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(top: BorderSide(color: lineStrongColor(context))),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 40,
                  offset: Offset(0, -12),
                ),
              ],
            ),
            child: Consumer<PlayerController>(
              builder: (context, player, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const SizedBox(height: 10),
                  Container(
                    width: 40,
                    height: 4.5,
                    decoration: BoxDecoration(
                      color: faintFor(context).withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  _header(context, player),
                  _stats(context, player),
                  if (player.queue.isEmpty)
                    const Expanded(
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: 60),
                          child: EmptyState(
                            title: '播放队列是空的',
                            icon: CupertinoIcons.music_note_list,
                          ),
                        ),
                      ),
                    )
                  else
                    Expanded(child: _list(context, player)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, PlayerController player) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '播放队列',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                color: textFor(context),
              ),
            ),
          ),
          _textAction(
            context,
            icon: CupertinoIcons.shuffle,
            label: '乱序',
            onTap: player.queue.length <= 1
                ? null
                : () {
                    player.shuffleQueue();
                    flmToast(context, '队列已重新打乱，当前歌回到第一位');
                  },
          ),
          _textAction(
            context,
            icon: CupertinoIcons.trash,
            label: '清空',
            danger: true,
            onTap: player.queue.isEmpty ? null : () => _clearQueue(context),
          ),
          Pressable(
            onTap: () => Navigator.pop(context),
            child: SizedBox(
              width: 32,
              height: 30,
              child: Icon(
                CupertinoIcons.chevron_down,
                size: 17,
                color: faintFor(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _textAction(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool danger = false,
  }) {
    final color = onTap == null
        ? faintFor(context).withValues(alpha: 0.5)
        : danger
            ? coralFor(context)
            : mutedFor(context);
    return Pressable(
      onTap: onTap,
      child: Container(
        height: 30,
        margin: const EdgeInsets.only(right: 5),
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: onTap == null ? Colors.transparent : surface2For(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: lineColor(context)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stats(BuildContext context, PlayerController player) {
    final total = player.queue.length;
    final played = player.index < 0 ? 0 : player.index;
    final remaining = _remainingInQueue(player.queue, player.index);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 7, 20, 9),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: lineColor(context))),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 3,
              children: <Widget>[
                Text(
                  '$total 首',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: textFor(context),
                  ),
                ),
                if (played > 0) ...<Widget>[
                  _sep(context),
                  Text('已播 $played', style: _statStyle(context)),
                ],
                if (remaining > Duration.zero) ...<Widget>[
                  _sep(context),
                  Text('剩余 ${formatDuration(remaining)}', style: _statStyle(context)),
                ],
              ],
            ),
          ),
          if (player.index >= 0)
            Text(
              '第 ${player.index + 1} / $total',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: accentFor(context),
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }

  TextStyle _statStyle(BuildContext context) => TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w500,
        color: mutedFor(context),
      );

  Widget _sep(BuildContext context) => Container(
        width: 1,
        height: 9,
        color: lineStrongColor(context),
      );

  Widget _list(BuildContext context, PlayerController player) {
    _entries = _buildEntries(player.queue, player.index);
    final entries = _entries;
    final currentRow = entries.indexWhere((entry) => entry.kind == _Kind.current);
    // Vertical padding of the list below; the viewport is the space left of it.
    const verticalInset = 6.0 + 26.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        // The ListView viewport is the full slot; the usable band for centring
        // excludes its vertical padding. Fixed extents make the playing row's
        // offset exact, so it lands dead-centre in the first painted frame.
        final viewport = constraints.maxHeight;
        final listHeight = viewport - verticalInset;
        final total =
            entries.fold<double>(0, (sum, entry) => sum + entry.extent);
        final maxScroll =
            (total + verticalInset - viewport).clamp(0.0, double.infinity);
        var initial = 0.0;
        if (currentRow >= 0) {
          initial = (_offsetOf(entries, currentRow) -
                  (listHeight - _currentExtent) / 2)
              .clamp(0.0, maxScroll)
              .toDouble();
        }
        _controller ??= ScrollController(initialScrollOffset: initial)
          ..addListener(_onScroll);
        _track(currentRow, listHeight);
        return Stack(
          children: <Widget>[
            ListView.builder(
              controller: _controller!,
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 26),
              itemCount: entries.length,
              itemBuilder: (context, row) {
                final entry = entries[row];
                return SizedBox(
                  height: entry.extent,
                  child: _row(context, player, entry),
                );
              },
            ),
            Positioned(left: 0, right: 0, bottom: 10, child: _locatePill(context, player)),
          ],
        );
      },
    );
  }

  Widget _locatePill(BuildContext context, PlayerController player) {
    final song = player.current;
    return AnimatedOpacity(
      duration: AuroraMotion.quick,
      curve: AuroraMotion.ease,
      opacity: _far && song != null ? 1 : 0,
      child: IgnorePointer(
        ignoring: !_far,
        child: Center(
          child: Pressable(
            onTap: _locate,
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 13),
              decoration: BoxDecoration(
                color: const Color(0xE6101519),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: accentBorderColor(context)),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x59000000),
                    blurRadius: 24,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(CupertinoIcons.location_solid, size: 13, color: accentFor(context)),
                  const SizedBox(width: 7),
                  Text(
                    '第 ${player.index + 1} / ${player.queue.length}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: accentFor(context),
                      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Text(
                      song?.displayTitle ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: textFor(context)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(CupertinoIcons.arrow_up, size: 12, color: faintFor(context)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, PlayerController player, _Entry entry) {
    switch (entry.kind) {
      case _Kind.headerNow:
        return _groupHeader(
          context,
          title: '正在播放',
          note: '${player.index + 1} / ${player.queue.length}',
          accent: true,
        );
      case _Kind.headerNext:
        return _groupHeader(
          context,
          title: '接下来 · ${player.queue.length - player.index - 1} 首',
        );
      case _Kind.current:
        return _playingRow(context, player);
      case _Kind.past:
        return _songRow(context, player, entry.queueIndex, played: true);
      case _Kind.upcoming:
        return _songRow(context, player, entry.queueIndex, played: false);
    }
  }

  Widget _groupHeader(
    BuildContext context, {
    required String title,
    String? note,
    bool accent = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: <Widget>[
          Text(
            title,
            style: TextStyle(
              fontSize: 8.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
              color: accent ? accentFor(context) : faintFor(context),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(child: Container(height: 1, color: lineColor(context))),
          if (note != null) ...<Widget>[
            const SizedBox(width: 9),
            Text(
              note,
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                color: faintFor(context),
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _playingRow(BuildContext context, PlayerController player) {
    final song = player.current;
    if (song == null) return const SizedBox.shrink();
    final quality = _qualityLabel(player.appState.settings.quality);
    return Pressable(
      onTap: _locate,
      onLongPress: () {
        player.removeFromQueue(song);
        flmToast(context, '已移出「${song.displayTitle}」');
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 1.5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accentBorderColor(context)),
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: <Color>[accentSoftColor(context), Colors.transparent],
            stops: const <double>[0, 0.85],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 24,
                child: EqBars(height: 12, color: accentFor(context)),
              ),
              const SizedBox(width: 8),
              CoverArt(song: song, size: 44, radius: 12),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      song.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: accentFor(context),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${song.displaySinger} · $quality',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: mutedFor(context)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatDuration(player.duration),
                style: TextStyle(
                  fontSize: 10.5,
                  color: faintFor(context),
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              _more(context, song),
            ],
          ),
        ),
      ),
    );
  }

  Widget _songRow(
    BuildContext context,
    PlayerController player,
    int index, {
    required bool played,
  }) {
    final song = player.queue[index];
    return Pressable(
      onTap: () {
        player.jumpToQueueIndex(index);
        Navigator.pop(context);
      },
      onLongPress: () {
        player.removeFromQueue(song);
        flmToast(context, '已移出「${song.displayTitle}」');
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 1.5),
        child: Opacity(
          opacity: played ? 0.55 : 1,
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 24,
                child: Text(
                  '${index + 1}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: faintFor(context),
                    fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              CoverArt(song: song, size: 40, radius: 11),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      song.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: textFor(context),
                      ),
                    ),
                    const SizedBox(height: 2.5),
                    Text(
                      song.displaySinger,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: faintFor(context)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (played)
                Icon(CupertinoIcons.checkmark, size: 13, color: faintFor(context))
              else
                Text(
                  formatInterval(song.interval),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: faintFor(context),
                    fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
              _more(context, song),
            ],
          ),
        ),
      ),
    );
  }

  Widget _more(BuildContext context, Song song) {
    return Pressable(
      onTap: () => showSongActions(context, song),
      child: SizedBox(
        width: 34,
        height: 40,
        child: Icon(CupertinoIcons.ellipsis, size: 15, color: faintFor(context)),
      ),
    );
  }
}

String _qualityLabel(String quality) {
  switch (quality) {
    case '128k':
      return '标准';
    case '320k':
      return '高品质';
    case 'flac':
      return '无损';
    case 'flac24bit':
      return '24bit';
    default:
      return quality;
  }
}
