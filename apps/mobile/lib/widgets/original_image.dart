import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../native/share_bridge.dart';
import 'itda_theme.dart';

class OriginalImagePreview extends StatelessWidget {
  const OriginalImagePreview({
    super.key,
    required this.original,
    required this.loading,
    this.onExpand,
  });

  final LocalSource? original;
  final bool loading;
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final path = original?.imagePath;
    return Padding(
      padding: const EdgeInsets.only(bottom: ItdaSpace.large),
      child: path != null && onExpand != null
          ? OriginalImage(path: path, onExpand: onExpand)
          : loading
          ? LinearProgressIndicator(semanticsLabel: copy.loadingImage)
          : Text(
              original == null
                  ? copy.remoteImageUnavailable
                  : copy.imageUnavailable,
              style: Theme.of(context).textTheme.bodySmall,
            ),
    );
  }
}
class OriginalImageOverlay extends StatelessWidget {
  const OriginalImageOverlay(
      {super.key, required this.path, required this.child});

  final String? path;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          Visibility(visible: path == null, maintainState: true, child: child),
          if (path case final image?) OriginalImage(path: image),
        ],
      );
}
class OriginalImage extends StatefulWidget {
  const OriginalImage({super.key, required this.path, this.onExpand});

  final String path;
  final VoidCallback? onExpand;

  @override
  State<OriginalImage> createState() => _OriginalImageState();
}
class _OriginalImageState extends State<OriginalImage> {
  bool get _expanded => widget.onExpand == null;
  late ResizeImage _provider = _imageProvider();

  ResizeImage _imageProvider() {
    final limit = _expanded ? 2048 : 1024;
    return ResizeImage(
      FileImage(File(widget.path)),
      width: limit,
      height: limit,
      policy: ResizeImagePolicy.fit,
      allowUpscaling: false,
    );
  }

  @override
  void didUpdateWidget(covariant OriginalImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.path != oldWidget.path ||
        _expanded != (oldWidget.onExpand == null)) {
      unawaited(_provider.evict());
      _provider = _imageProvider();
    }
  }

  @override
  void dispose() {
    unawaited(_provider.evict());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final copy = AppLocalizations.of(context);
    final image = Image(
      image: _provider,
      width: double.infinity,
      fit: BoxFit.contain,
      semanticLabel: copy.imageViewer,
      frameBuilder: (context, child, frame, synchronouslyLoaded) {
        if (frame == null && !synchronouslyLoaded) {
          return SizedBox(
            height: 120,
            child: Center(
              child:
                  CircularProgressIndicator(semanticsLabel: copy.loadingImage),
            ),
          );
        }
        if (_expanded) return child;
        return Semantics(
          button: true,
          label: copy.openImage,
          child: InkWell(
            onTap: widget.onExpand,
            child: ExcludeSemantics(child: child),
          ),
        );
      },
      errorBuilder: (_, __, ___) => Center(
        child: Semantics(
          liveRegion: true,
          child: Text(copy.imageUnavailable),
        ),
      ),
    );
    if (_expanded) {
      return InteractiveViewer(
        maxScale: 4,
        child: SizedBox.expand(child: image),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 360),
      child: image,
    );
  }
}
