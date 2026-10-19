import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/online_engine.dart';
import '../../state/app_state.dart';
import '../../state/library_state.dart';
import '../../state/player_state.dart';
import '../kit.dart';
import 'cover_art.dart';
import 'song_tile.dart' show srcShortLabel;

Future<void> showSongActions(
  BuildContext context,
  Song song, {
  List<Song>? queue,
  int? index,
}) {
  final player = context.read<PlayerController>();
  final library = context.read<LibraryState>();
  final appState = context.read<AppState>();
  final online = context.read<OnlineEngine>();

  return showFlmSheet<void>(
    context,
    title: '歌曲',
    child: Builder(
      builder: (sheetContext) {
        final loved = library.isLoved(song);
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 6),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(kGutter, 4, kGutter, 14),
              child: Row(
                children: <Widget>[
                  CoverArt(song: song, size: 44, radius: 11),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          song.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: textFor(sheetContext),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          song.displaySinger,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 9.5,
                            color: faintFor(sheetContext),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SrcBadge(srcShortLabel(song.source)),
                ],
              ),
            ),
            SheetAction(
              icon: CupertinoIcons.play_fill,
              label: '播放',
              onTap: () {
                Navigator.pop(sheetContext);
                player.playSong(song, queue: queue, index: index);
              },
            ),
            SheetAction(
              icon: CupertinoIcons.music_note_list,
              label: '添加到列表',
              onTap: () {
                Navigator.pop(sheetContext);
                showAddToPlaylist(context, song);
              },
            ),
            SheetAction(
              icon: loved ? CupertinoIcons.heart_fill : CupertinoIcons.heart,
              label: loved ? '取消收藏' : '收藏',
              accentIcon: loved,
              onTap: () {
                final nowLoved = library.toggleLove(song);
                Navigator.pop(sheetContext);
                flmToast(context, nowLoved ? '已收藏到「我喜欢」' : '已取消收藏');
              },
            ),
            SheetAction(
              icon: CupertinoIcons.xmark_circle_fill,
              label: '不感兴趣',
              subtitle: '随机播放时会尽量跳过这首歌',
              danger: true,
              onTap: () {
                appState.dislike(song);
                Navigator.pop(sheetContext);
                if (player.isCurrent(song)) {
                  player.next();
                }
                flmToast(context, '已加入不喜欢规则');
              },
            ),
            if (!song.isLocal)
              SheetAction(
                icon: CupertinoIcons.square_arrow_up,
                label: '打开歌曲详情页',
                onTap: () async {
                  Navigator.pop(sheetContext);
                  try {
                    final value = await online.call(
                      'musicDetailUrl',
                      <String, dynamic>{'source': song.source, 'song': song.raw},
                    );
                    final url = '$value';
                    if (url.isNotEmpty) {
                      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                    }
                  } catch (_) {}
                },
              ),
            SheetAction(
              icon: CupertinoIcons.doc,
              label: '复制歌名',
              onTap: () {
                final text = song.singer.isEmpty ? song.name : '${song.name} - ${song.singer}';
                Clipboard.setData(ClipboardData(text: text));
                Navigator.pop(sheetContext);
                flmToast(context, '已复制歌名');
              },
            ),
          ],
        );
      },
    ),
  );
}

Future<void> showAddToPlaylist(BuildContext context, Song song) {
  final library = context.read<LibraryState>();
  return _showPlaylistPicker(
    context,
    title: '添加到列表',
    library: library,
    onPick: (playlist) => library.addSong(playlist.id, song),
    onNewPlaylist: (name) => library.createPlaylist(name),
  );
}

Future<void> showSongsToPlaylist(BuildContext context, List<Song> songs) {
  final library = context.read<LibraryState>();
  return _showPlaylistPicker(
    context,
    title: '添加 ${songs.length} 首歌曲到列表',
    library: library,
    onPick: (playlist) => library.addSongs(playlist.id, songs),
  );
}

Future<void> _showPlaylistPicker(
  BuildContext context, {
  required String title,
  required LibraryState library,
  required void Function(Playlist playlist) onPick,
  void Function(String name)? onNewPlaylist,
}) {
  final playlists = <Playlist>[
    library.defaultPlaylist,
    library.lovePlaylist,
    ...library.userPlaylists,
  ];
  return showFlmSheet<void>(
    context,
    title: title,
    child: Builder(
      builder: (sheetContext) {
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 6),
          children: <Widget>[
            for (final playlist in playlists)
              SheetAction(
                icon: playlist.id == 'love'
                    ? CupertinoIcons.heart
                    : playlist.id == 'local'
                        ? CupertinoIcons.folder
                        : playlist.id == 'default'
                            ? CupertinoIcons.music_note
                            : CupertinoIcons.music_albums,
                label: playlist.name,
                subtitle: '${playlist.songs.length} 首',
                onTap: () {
                  onPick(playlist);
                  Navigator.pop(sheetContext);
                  flmToast(context, '已添加到「${playlist.name}」');
                },
              ),
            if (onNewPlaylist != null)
              SheetAction(
                icon: CupertinoIcons.plus,
                label: '新建列表',
                onTap: () async {
                  Navigator.pop(sheetContext);
                  final name = await flmInputDialog(
                    context,
                    title: '新建列表',
                    message: '给这个列表起一个名字。',
                    placeholder: '列表名称',
                    confirmLabel: '创建',
                  );
                  if (name == null || name.trim().isEmpty) return;
                  onNewPlaylist(name.trim());
                  if (!context.mounted) return;
                  flmToast(context, '已创建「${name.trim()}」');
                },
              ),
          ],
        );
      },
    ),
  );
}
