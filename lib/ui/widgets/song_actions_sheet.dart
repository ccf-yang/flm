import 'package:flutter/material.dart';
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
import 'cover_art.dart';

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

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 12),
              child: Row(
                children: <Widget>[
                  CoverArt(song: song, size: 48, radius: 10),
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
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: textFor(sheetContext),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          song.displaySinger,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: mutedFor(sheetContext)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: Theme.of(sheetContext).dividerColor),
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: const Text('播放'),
              onTap: () {
                Navigator.pop(sheetContext);
                player.playSong(song, queue: queue, index: index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add_rounded),
              title: const Text('添加到列表'),
              onTap: () {
                Navigator.pop(sheetContext);
                showAddToPlaylist(context, song);
              },
            ),
            ListTile(
              leading: Icon(
                library.isLoved(song) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                color: library.isLoved(song) ? AppColors.accent : null,
              ),
              title: Text(library.isLoved(song) ? '取消收藏' : '收藏'),
              onTap: () {
                final loved = library.toggleLove(song);
                Navigator.pop(sheetContext);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(loved ? '已收藏' : '已取消收藏')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.block_rounded),
              title: const Text('不感兴趣'),
              subtitle: const Text('之后随机播放时会尽量跳过这首歌'),
              onTap: () {
                appState.dislike(song);
                Navigator.pop(sheetContext);
                if (player.isCurrent(song)) {
                  player.next();
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已加入不喜欢规则')),
                );
              },
            ),
            if (!song.isLocal)
              ListTile(
                leading: const Icon(Icons.open_in_new_rounded),
                title: const Text('打开歌曲详情页'),
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
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('复制歌名'),
              onTap: () {
                final text = song.singer.isEmpty ? song.name : '${song.name} - ${song.singer}';
                Clipboard.setData(ClipboardData(text: text));
                Navigator.pop(sheetContext);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制')),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

Future<void> showAddToPlaylist(BuildContext context, Song song) {
  final library = context.read<LibraryState>();
  final playlists = <Playlist>[
    library.defaultPlaylist,
    library.lovePlaylist,
    ...library.userPlaylists,
  ];
  return showModalBottomSheet<void>(
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
                  '添加到列表',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: textFor(sheetContext),
                  ),
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: playlists.length,
                itemBuilder: (context, index) {
                  final playlist = playlists[index];
                  return ListTile(
                    leading: Icon(
                      playlist.id == 'love'
                          ? Icons.favorite_border_rounded
                          : playlist.id == 'local'
                              ? Icons.folder_rounded
                              : Icons.queue_music_rounded,
                    ),
                    title: Text(playlist.name),
                    subtitle: Text('${playlist.songs.length} 首'),
                    onTap: () {
                      library.addSong(playlist.id, song);
                      Navigator.pop(sheetContext);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已添加到「${playlist.name}」')),
                      );
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

Future<void> showSongsToPlaylist(BuildContext context, List<Song> songs) {
  final library = context.read<LibraryState>();
  final playlists = <Playlist>[
    library.defaultPlaylist,
    library.lovePlaylist,
    ...library.userPlaylists,
  ];
  return showModalBottomSheet<void>(
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
                  '添加 ${songs.length} 首歌曲到列表',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: textFor(sheetContext),
                  ),
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: playlists.length,
                itemBuilder: (context, index) {
                  final playlist = playlists[index];
                  return ListTile(
                    leading: const Icon(Icons.queue_music_rounded),
                    title: Text(playlist.name),
                    subtitle: Text('${playlist.songs.length} 首'),
                    onTap: () {
                      library.addSongs(playlist.id, songs);
                      Navigator.pop(sheetContext);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已添加到「${playlist.name}」')),
                      );
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
