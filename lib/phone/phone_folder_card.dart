// Archive on the phone: every saved item is a FOLDER.
//
// A manila-style folder: a tab at the top left that carries the item's
// Archive tag (its name, in the tag's colour), a body with a picture of the
// saved content on top (40% of the folder's height) and the title and source
// under it. All of it is the item's own data: its thumbnail or picture, title,
// source, description and tags. Nothing is invented; an item without a picture
// shows its own text there instead, and a picture that cannot be read falls
// back to the same, so a missing preview never changes the layout.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../app/app_state.dart';
import '../data/models/object_library_models.dart';
import '../features/links/link_tags.dart';
import '../new_ui/new_archive_page.dart'
    show archiveIconOf, archiveImageOf, archiveMetaOf;
import '../new_ui/new_folder_colors.dart' show contrastOn;
import '../app/theme.dart';
import 'phone_tokens.dart';
import 'phone_widgets.dart';

/// The label and colour on a folder's tab: the item's Archive category when it
/// has one (what the share sheet saves), else its first custom tag.
({String label, Color color})? archiveTagOf(AppState s, LibraryObject o) {
  final categories = LinkTag.of(s.library.categoriesOf(o.id));
  if (categories.isNotEmpty) {
    return (label: categories.first.label, color: categories.first.color);
  }
  for (final id in s.library.tagIdsOf(o.id)) {
    final tag = s.workspace.customTags[id];
    if (tag != null) return (label: tag.name, color: Color(tag.color));
  }
  return null;
}

class ArchiveFolderCard extends StatelessWidget {
  const ArchiveFolderCard({
    super.key,
    required this.state,
    required this.object,
    this.onTap,
    this.onLongPress,
  });

  final AppState state;
  final LibraryObject object;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Every folder has this size, so a column of them is even.
  static const height = 196.0;
  static const tabHeight = 20.0;
  static const tabWidth = 116.0;

  /// The picture takes two fifths of the folder.
  static const previewFraction = 0.4;
  static const previewHeight = height * previewFraction;
  static const gap = 12.0;

  @override
  Widget build(BuildContext context) {
    final tag = archiveTagOf(state, object);
    // Without a tag the folder is a neutral steel; with one it is tinted.
    final tint = tag?.color ?? AppColors.textFaint;
    final title = object.title.trim().isEmpty ? 'Untitled' : object.title;
    final when = object.lastSavedAt ?? object.createdAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PhoneSpace.margin,
        0,
        PhoneSpace.margin,
        gap,
      ),
      child: Semantics(
        button: true,
        label: '$title, ${tag?.label ?? archiveMetaOf(object)}',
        excludeSemantics: true,
        child: Press(
          onTap: onTap,
          onLongPress: onLongPress,
          child: SizedBox(
            key: const ValueKey('folder-body'),
            height: height,
            child: CustomPaint(
              painter: _FolderPainter(
                tint: tint,
                body: Color.lerp(AppColors.card, tint, 0.13)!,
                border: AppColors.border,
              ),
              child: Stack(
                children: [
                  Positioned(
                    left: 12,
                    top: 0,
                    width: tabWidth - 24,
                    height: tabHeight,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        tag?.label ?? archiveMetaOf(object),
                        key: const ValueKey('folder-tab'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.sizeMeta,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                          color: contrastOn(tint),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    right: 8,
                    top: tabHeight + 8,
                    height: previewHeight,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      child: _Preview(
                        key: const ValueKey('folder-preview'),
                        state: state,
                        object: object,
                        tint: tint,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 14,
                    right: 14,
                    top: tabHeight + 8 + previewHeight + 10,
                    bottom: 10,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: PhoneType.row.copyWith(
                            fontSize: AppType.sizeHeading,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${archiveMetaOf(object)} · ${relativeDay(when)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: PhoneType.meta,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The saved picture, or the item's own text when there is none (or it cannot
/// be read).
class _Preview extends StatelessWidget {
  const _Preview({
    super.key,
    required this.state,
    required this.object,
    required this.tint,
  });

  final AppState state;
  final LibraryObject object;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final image = archiveImageOf(state, object);
    final fallback = _TextPreview(object: object, tint: tint);
    if (image == null) return fallback;
    return Image(
      // Decoded near its on-screen size, so a long list stays light.
      image: ResizeImage(image, width: 720, policy: ResizeImagePolicy.fit),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}

class _TextPreview extends StatelessWidget {
  const _TextPreview({required this.object, required this.tint});

  final LibraryObject object;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final snippet =
        (object.type == LibraryObjectType.note
                ? (object.content ?? '')
                : (object.description ?? object.summary ?? ''))
            .trim();
    return ColoredBox(
      color: Color.lerp(AppColors.surfaceSecondary, tint, 0.2)!,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(archiveIconOf(object), size: 18, color: AppColors.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                snippet.isEmpty ? archiveMetaOf(object) : snippet,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: PhoneType.body.copyWith(
                  fontSize: AppType.sizeBodySmall,
                  height: 1.3,
                  color: AppColors.text.withValues(alpha: 0.8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The folder: a tab on the top left, a rounded body with a hairline edge.
class _FolderPainter extends CustomPainter {
  const _FolderPainter({
    required this.tint,
    required this.body,
    required this.border,
  });

  final Color tint;
  final Color body;
  final Color border;

  @override
  void paint(Canvas canvas, Size size) {
    const tabH = ArchiveFolderCard.tabHeight;
    const tabW = ArchiveFolderCard.tabWidth;
    const r = 14.0;
    final tab = Path()
      ..moveTo(0, tabH + 4)
      ..lineTo(0, 8)
      ..quadraticBezierTo(0, 0, 8, 0)
      ..lineTo(tabW - 14, 0)
      ..quadraticBezierTo(tabW - 6, 0, tabW - 2, tabH * 0.55)
      ..lineTo(tabW + 6, tabH + 4)
      ..close();
    canvas.drawPath(tab, Paint()..color = tint);
    final bodyRect = RRect.fromRectAndCorners(
      Rect.fromLTWH(0, tabH, size.width, size.height - tabH),
      topLeft: const Radius.circular(AppRadii.xs),
      topRight: const Radius.circular(r),
      bottomLeft: const Radius.circular(r),
      bottomRight: const Radius.circular(r),
    );
    canvas.drawRRect(bodyRect, Paint()..color = body);
    canvas.drawRRect(
      bodyRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = border,
    );
  }

  @override
  bool shouldRepaint(_FolderPainter old) =>
      old.tint != tint || old.body != body || old.border != border;
}

/// A light movement while scrolling: a folder is a little smaller the further
/// it is from the middle of the screen, and settles to full size in the
/// middle. Only the visible folders do any work, nothing runs while the list
/// rests, and it is off when the system asks for less motion.
class ScrollDepth extends StatefulWidget {
  const ScrollDepth({super.key, required this.child});

  final Widget child;

  /// Smallest scale (at the top and bottom edge of the screen).
  static const edgeScale = 0.94;

  /// The scale for a folder whose centre is [distance] from the middle of the
  /// viewport, as a fraction of the viewport's height (0 = middle).
  static double scaleFor(double distance) =>
      1 - (1 - edgeScale) * distance.abs().clamp(0.0, 1.0);

  @override
  State<ScrollDepth> createState() => _ScrollDepthState();
}

class _ScrollDepthState extends State<ScrollDepth> {
  ScrollPosition? _position;

  @override
  void initState() {
    super.initState();
    // Right after the first layout, so a list that has not been touched yet
    // already shows the depth.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _changed();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Scrollable.maybeOf(context)?.position;
    if (next != _position) {
      _position?.removeListener(_changed);
      _position = next?..addListener(_changed);
    }
  }

  @override
  void dispose() {
    _position?.removeListener(_changed);
    super.dispose();
  }

  double _scale = 1;

  void _changed() {
    final box = context.findRenderObject();
    final position = _position;
    if (position == null ||
        box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        !position.hasViewportDimension ||
        position.viewportDimension <= 0) {
      return;
    }
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;
    // Scroll offset at which this folder would be in the middle, versus now.
    final centred = viewport.getOffsetToReveal(box, 0.5).offset;
    final distance = (centred - position.pixels) / position.viewportDimension;
    final scale = ScrollDepth.scaleFor(distance);
    if ((scale - _scale).abs() < 0.002) return;
    setState(() => _scale = scale);
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context) || _scale == 1) {
      return RepaintBoundary(child: widget.child);
    }
    return RepaintBoundary(
      child: Transform.scale(scale: _scale, child: widget.child),
    );
  }
}
