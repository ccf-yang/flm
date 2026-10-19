import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

class LocalMetadata {
  const LocalMetadata({
    required this.title,
    this.artist = '',
    this.album = '',
    this.picture,
  });

  final String title;
  final String artist;
  final String album;
  final Uint8List? picture;
}

class LocalMetadataReader {
  static Future<LocalMetadata> read(File file) async {
    final bytes = await file.readAsBytes();
    final fallback = _fromFileName(file.path);
    try {
      final extension = p.extension(file.path).toLowerCase();
      switch (extension) {
        case '.mp3':
          return _readId3(bytes) ?? fallback;
        case '.flac':
          return _readFlac(bytes) ?? fallback;
        case '.m4a':
        case '.mp4':
        case '.aac':
          return _readMp4(bytes) ?? fallback;
        default:
          return fallback;
      }
    } catch (_) {
      return fallback;
    }
  }

  static LocalMetadata _fromFileName(String path) {
    var base = p.basenameWithoutExtension(path).trim();
    if (base.isEmpty) base = '未知歌曲';
    final parts = base.split(' - ');
    if (parts.length >= 2) {
      final title = parts.first.trim();
      final artist = parts.sublist(1).join(' - ').trim();
      if (title.isNotEmpty) {
        return LocalMetadata(title: title, artist: artist);
      }
    }
    return LocalMetadata(title: base);
  }

  static LocalMetadata? _readId3(Uint8List bytes) {
    if (bytes.length < 10) return null;
    if (bytes[0] != 0x49 || bytes[1] != 0x44 || bytes[2] != 0x33) return null;
    final major = bytes[3];
    final flags = bytes[5];
    final size = _syncSafe(bytes, 6);
    var offset = 10;
    if (flags & 0x40 != 0 && offset + 4 <= bytes.length) {
      final extended = _u32be(bytes, offset);
      offset += 4 + extended;
    }
    final end = (10 + size).clamp(0, bytes.length).toInt();
    String? title;
    String? artist;
    String? album;
    Uint8List? picture;

    while (offset + 10 <= end) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      if (!RegExp(r'^[A-Z0-9]{4}$').hasMatch(id)) break;
      final frameSize = major >= 4 ? _syncSafe(bytes, offset + 4) : _u32be(bytes, offset + 4);
      final frameFlags = _u16be(bytes, offset + 8);
      final dataStart = offset + 10;
      final dataEnd = dataStart + frameSize;
      if (frameSize <= 0 || dataEnd > end) break;
      final data = bytes.sublist(dataStart, dataEnd);

      if (id.startsWith('T') && data.isNotEmpty) {
        final value = _decodeTextFrame(data, id == 'TXXX');
        if (id == 'TIT2' && value.isNotEmpty) title = value;
        if (id == 'TPE1' && value.isNotEmpty) artist = value;
        if (id == 'TALB' && value.isNotEmpty) album = value;
      } else if (id == 'APIC') {
        picture ??= _decodeApic(data);
      }
      offset = dataEnd;
      if (frameFlags & 0x0040 != 0) {
        // Grouping identity byte.
        offset += 1;
      }
    }

    if ((title ?? '').isEmpty && (artist ?? '').isEmpty && picture == null) {
      return null;
    }
    return LocalMetadata(
      title: (title ?? '').trim(),
      artist: (artist ?? '').trim(),
      album: (album ?? '').trim(),
      picture: picture,
    );
  }

  static String _decodeTextFrame(Uint8List data, bool isTxxx) {
    if (data.isEmpty) return '';
    final encoding = data[0];
    var payload = data.sublist(1);
    if (isTxxx) {
      final separator = _textSeparator(payload, encoding);
      if (separator >= 0) {
        final step = (encoding == 1 || encoding == 2) ? 2 : 1;
        payload = payload.sublist(separator + step);
      }
    }
    return _decodeText(payload, encoding).replaceAll('\u0000', '').trim();
  }

  static Uint8List? _decodeApic(Uint8List data) {
    if (data.length < 4) return null;
    final encoding = data[0];
    var offset = 1;
    while (offset < data.length && data[offset] != 0) {
      offset++;
    }
    offset++; // mime terminator
    if (offset >= data.length) return null;
    offset++; // picture type
    final separator = _textSeparator(data.sublist(offset), encoding);
    if (separator >= 0) {
      offset += separator + ((encoding == 1 || encoding == 2) ? 2 : 1);
    }
    if (offset >= data.length) return null;
    return data.sublist(offset);
  }

  static int _textSeparator(Uint8List data, int encoding) {
    if (encoding == 1 || encoding == 2) {
      for (var i = 0; i + 1 < data.length; i += 2) {
        if (data[i] == 0 && data[i + 1] == 0) return i;
      }
      return -1;
    }
    return data.indexOf(0);
  }

  static String _decodeText(Uint8List data, int encoding) {
    switch (encoding) {
      case 1:
        if (data.length >= 2 && data[0] == 0xFF && data[1] == 0xFE) {
          return _utf16(data.sublist(2), littleEndian: true);
        }
        if (data.length >= 2 && data[0] == 0xFE && data[1] == 0xFF) {
          return _utf16(data.sublist(2), littleEndian: false);
        }
        return _utf16(data, littleEndian: true);
      case 2:
        return _utf16(data, littleEndian: false);
      case 3:
        return utf8.decode(data, allowMalformed: true);
      default:
        return latin1.decode(data, allowInvalid: true);
    }
  }

  static String _utf16(Uint8List data, {required bool littleEndian}) {
    final codeUnits = <int>[];
    for (var i = 0; i + 1 < data.length; i += 2) {
      final value = littleEndian ? data[i] | (data[i + 1] << 8) : (data[i] << 8) | data[i + 1];
      if (value == 0) break;
      codeUnits.add(value);
    }
    return String.fromCharCodes(codeUnits);
  }

  static LocalMetadata? _readFlac(Uint8List bytes) {
    if (bytes.length < 8) return null;
    if (bytes[0] != 0x66 || bytes[1] != 0x4C || bytes[2] != 0x61 || bytes[3] != 0x43) {
      return null;
    }
    var offset = 4;
    String? title;
    String? artist;
    String? album;
    Uint8List? picture;
    var last = false;
    while (!last && offset + 4 <= bytes.length) {
      final header = bytes[offset];
      last = (header & 0x80) != 0;
      final type = header & 0x7F;
      final length = (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
      offset += 4;
      final end = (offset + length).clamp(0, bytes.length).toInt();
      if (type == 4) {
        final comments = _readVorbisComments(bytes.sublist(offset, end));
        title ??= comments['TITLE'];
        artist ??= comments['ARTIST'];
        album ??= comments['ALBUM'];
      } else if (type == 6) {
        picture ??= _readFlacPicture(bytes.sublist(offset, end));
      }
      offset = end;
    }
    if ((title ?? '').isEmpty && (artist ?? '').isEmpty && picture == null) {
      return null;
    }
    return LocalMetadata(
      title: (title ?? '').trim(),
      artist: (artist ?? '').trim(),
      album: (album ?? '').trim(),
      picture: picture,
    );
  }

  static Map<String, String> _readVorbisComments(Uint8List data) {
    final result = <String, String>{};
    if (data.length < 8) return result;
    var offset = 0;
    final vendorLength = _u32le(data, offset);
    offset += 4 + vendorLength;
    if (offset + 4 > data.length) return result;
    final count = _u32le(data, offset);
    offset += 4;
    for (var i = 0; i < count && offset + 4 <= data.length; i++) {
      final length = _u32le(data, offset);
      offset += 4;
      if (length < 0 || offset + length > data.length) break;
      final comment = utf8.decode(data.sublist(offset, offset + length), allowMalformed: true);
      final index = comment.indexOf('=');
      if (index > 0) {
        result[comment.substring(0, index).toUpperCase()] = comment.substring(index + 1);
      }
      offset += length;
    }
    return result;
  }

  static Uint8List? _readFlacPicture(Uint8List data) {
    if (data.length < 32) return null;
    var offset = 0;
    offset += 4; // picture type
    final mimeLength = _u32be(data, offset);
    offset += 4 + mimeLength;
    final descriptionLength = _u32be(data, offset);
    offset += 4 + descriptionLength;
    offset += 16; // width, height, depth, colors
    if (offset + 4 > data.length) return null;
    final dataLength = _u32be(data, offset);
    offset += 4;
    if (dataLength <= 0 || offset + dataLength > data.length) return null;
    return data.sublist(offset, offset + dataLength);
  }

  static LocalMetadata? _readMp4(Uint8List bytes) {
    final tags = <String, String>{};
    Uint8List? picture;

    void walk(int start, int end, {bool isIlst = false}) {
      var offset = start;
      while (offset + 8 <= end) {
        final size = _u32be(bytes, offset);
        if (size < 8) break;
        final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
        final atomEnd = (offset + size).clamp(0, end).toInt();
        if (isIlst) {
          final key = _atomKey(bytes, offset + 4, offset + 8);
          final value = _readIlstValue(bytes, offset + 8, atomEnd);
          if (key == '©nam' && value.text != null) tags['title'] = value.text!;
          if (key == '©ART' && value.text != null) tags['artist'] = value.text!;
          if (key == '©alb' && value.text != null) tags['album'] = value.text!;
          if (key == 'covr' && value.bytes != null) picture ??= value.bytes;
        } else if (type == 'moov' || type == 'udta' || type == 'trak' || type == 'mdia' ||
            type == 'minf' || type == 'stbl' || type == 'edts') {
          walk(offset + 8, atomEnd);
        } else if (type == 'meta') {
          walk(offset + 12, atomEnd);
        } else if (type == 'ilst') {
          walk(offset + 8, atomEnd, isIlst: true);
        }
        offset = atomEnd;
      }
    }

    walk(0, bytes.length);
    if (tags.isEmpty && picture == null) return null;
    return LocalMetadata(
      title: (tags['title'] ?? '').trim(),
      artist: (tags['artist'] ?? '').trim(),
      album: (tags['album'] ?? '').trim(),
      picture: picture,
    );
  }

  static String _atomKey(Uint8List bytes, int start, int end) {
    if (end - start != 4) return '';
    if (bytes[start] == 0xA9) {
      return '©${String.fromCharCodes(bytes.sublist(start + 1, end))}';
    }
    return String.fromCharCodes(bytes.sublist(start, end));
  }

  static _IlstValue _readIlstValue(Uint8List bytes, int start, int end) {
    var offset = start;
    while (offset + 8 <= end) {
      final size = _u32be(bytes, offset);
      if (size < 8) break;
      final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
      final atomEnd = (offset + size).clamp(0, end).toInt();
      if (type == 'data' && offset + 16 <= atomEnd) {
        final dataType = _u32be(bytes, offset + 8) & 0x00FFFFFF;
        final valueStart = offset + 16;
        final value = bytes.sublist(valueStart, atomEnd);
        if (dataType == 1 || dataType == 2) {
          return _IlstValue(text: utf8.decode(value, allowMalformed: true));
        }
        if (dataType == 13 || dataType == 14 || dataType == 12) {
          return _IlstValue(bytes: value);
        }
        if (dataType == 21 || dataType == 0) {
          return _IlstValue(bytes: value);
        }
      }
      offset = atomEnd;
    }
    return const _IlstValue();
  }

  static int _syncSafe(Uint8List bytes, int offset) {
    if (offset + 4 > bytes.length) return 0;
    return ((bytes[offset] & 0x7F) << 21) |
        ((bytes[offset + 1] & 0x7F) << 14) |
        ((bytes[offset + 2] & 0x7F) << 7) |
        (bytes[offset + 3] & 0x7F);
  }

  static int _u16be(Uint8List bytes, int offset) {
    if (offset + 2 > bytes.length) return 0;
    return (bytes[offset] << 8) | bytes[offset + 1];
  }

  static int _u32be(Uint8List bytes, int offset) {
    if (offset + 4 > bytes.length) return 0;
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  static int _u32le(Uint8List bytes, int offset) {
    if (offset + 4 > bytes.length) return 0;
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }
}

class _IlstValue {
  const _IlstValue({this.text, this.bytes});

  final String? text;
  final Uint8List? bytes;
}
