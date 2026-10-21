import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Title, description and preview image of a web page.
class LinkPreview {
  const LinkPreview({
    this.title,
    this.description,
    this.siteName,
    this.imageUrl,
  });

  final String? title;
  final String? description;
  final String? siteName;
  final String? imageUrl;
}

/// Reads public metadata of a page (like a browser opening it). Only the
/// URL itself is sent; nothing from your workspace leaves the computer.
class LinkPreviewFetcher {
  static const _maxHtmlBytes = 768 * 1024;
  static const _maxImageBytes = 5 * 1024 * 1024;
  static const _timeout = Duration(seconds: 8);
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0 Safari/537.36 THEapp/1.0';

  Future<LinkPreview?> fetch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      request.headers
        ..set(HttpHeaders.userAgentHeader, _userAgent)
        ..set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml');
      final response = await request.close().timeout(_timeout);
      final type = response.headers.contentType?.mimeType ?? '';
      if (response.statusCode >= 400 || !type.contains('html')) {
        await response.drain<void>();
        return null;
      }
      final bytes = await _readLimited(response, _maxHtmlBytes);
      final html = utf8.decode(bytes, allowMalformed: true);
      final base = response.redirects.isEmpty
          ? uri
          : uri.resolveUri(response.redirects.last.location);
      return parseHtml(html, base);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads a preview image; returns bytes and file extension.
  Future<(Uint8List, String)?> downloadImage(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final response = await request.close().timeout(_timeout);
      final type = response.headers.contentType;
      if (response.statusCode >= 400 || type?.primaryType != 'image') {
        await response.drain<void>();
        return null;
      }
      final ext = switch (type!.subType) {
        'jpeg' || 'jpg' => 'jpg',
        'png' => 'png',
        'gif' => 'gif',
        'webp' => 'webp',
        _ => null,
      };
      if (ext == null) {
        await response.drain<void>();
        return null;
      }
      final bytes = await _readLimited(response, _maxImageBytes);
      return (bytes, ext);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<Uint8List> _readLimited(
    Stream<List<int>> stream,
    int limit,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream.timeout(_timeout)) {
      builder.add(chunk);
      if (builder.length >= limit) break;
    }
    return builder.takeBytes();
  }

  static LinkPreview parseHtml(String html, Uri base) {
    String? meta(String key) {
      final patterns = [
        RegExp(
          '<meta[^>]+(?:property|name)=["\']$key["\'][^>]*content=["\']([^"\']*)["\']',
          caseSensitive: false,
        ),
        RegExp(
          '<meta[^>]+content=["\']([^"\']*)["\'][^>]*(?:property|name)=["\']$key["\']',
          caseSensitive: false,
        ),
      ];
      for (final p in patterns) {
        final m = p.firstMatch(html);
        if (m != null && m.group(1)!.trim().isNotEmpty) {
          return decodeEntities(m.group(1)!.trim());
        }
      }
      return null;
    }

    final titleTag = RegExp(
      r'<title[^>]*>([\s\S]*?)</title>',
      caseSensitive: false,
    ).firstMatch(html)?.group(1);
    final title =
        meta('og:title') ??
        meta('twitter:title') ??
        (titleTag == null
            ? null
            : decodeEntities(titleTag.replaceAll(RegExp(r'\s+'), ' ').trim()));
    var image = meta('og:image') ?? meta('twitter:image');
    if (image != null) {
      image = base.resolve(image).toString();
    }
    return LinkPreview(
      title: title == null || title.isEmpty ? null : title,
      description: meta('og:description') ?? meta('description'),
      siteName: meta('og:site_name'),
      imageUrl: image,
    );
  }

  static String decodeEntities(String s) => s
      .replaceAllMapped(
        RegExp(r'&#x([0-9a-fA-F]+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
      )
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!)),
      )
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');
}
