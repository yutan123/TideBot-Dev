import 'dart:convert';

/// Validation shared by plugin media downloads and message delivery.
class PluginMediaContract {
  static const permissions = {
    'storage',
    'network',
    'chat.send',
    'media.download',
  };
  static const limits = {
    'image': 10 * 1024 * 1024,
    'video': 40 * 1024 * 1024,
    'audio': 20 * 1024 * 1024,
  };

  static Uri uri(Object? value, List origins) {
    if (value is! String) throw const FormatException('url 必须为 HTTPS 地址');
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        !origins.contains(uri.origin)) {
      throw const FormatException('媒体地址必须属于 networkOrigins 中声明的 HTTPS origin');
    }
    return uri;
  }

  static String text(
    Object? value,
    String field,
    int max, {
    bool required = false,
  }) {
    if (value == null && !required) return '';
    if (value is! String ||
        value.length > max ||
        (required && value.trim().isEmpty)) {
      throw FormatException('$field 必须为${required ? "非空" : ""}字符串，最多 $max 字符');
    }
    return value;
  }

  /// Inspect signatures, rather than trusting extensions or Content-Type.
  static String extension(List<int> bytes, String kind) {
    bool at(int offset, List<int> magic) =>
        bytes.length >= offset + magic.length &&
        List.generate(
          magic.length,
          (i) => bytes[offset + i] == magic[i],
        ).every((v) => v);
    bool word(int offset, String s) => at(offset, ascii.encode(s));
    if (kind == 'image') {
      if (at(0, [137, 80, 78, 71, 13, 10, 26, 10])) return 'png';
      if (at(0, [255, 216, 255])) return 'jpg';
      if (word(0, 'GIF87a') || word(0, 'GIF89a')) return 'gif';
      if (word(0, 'RIFF') && word(8, 'WEBP')) return 'webp';
    } else if (kind == 'video') {
      if (word(4, 'ftyp')) return 'mp4';
      if (at(0, [26, 69, 223, 163])) return 'webm';
    } else if (kind == 'audio') {
      if (word(0, 'RIFF') && word(8, 'WAVE')) return 'wav';
      if (word(0, 'OggS')) return 'ogg';
      if (word(0, 'fLaC')) return 'flac';
      if (word(0, '#!AMR')) return 'amr';
      if (word(4, 'ftyp')) return 'm4a';
      if (word(0, 'ID3')) return 'mp3';
      if (bytes.length > 1 && bytes[0] == 255 && (bytes[1] & 246) == 240)
        return 'aac';
      if (bytes.length > 1 && bytes[0] == 255 && (bytes[1] & 224) == 224)
        return 'mp3';
    }
    throw const FormatException('媒体内容与类型不匹配或格式不支持');
  }
}
