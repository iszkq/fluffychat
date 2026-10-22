// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Counts touches across the entire pager, including adjacent visible pages.
class ImageViewerGestureScope extends StatefulWidget {
  final Widget child;

  const ImageViewerGestureScope({required this.child, super.key});

  @override
  State<ImageViewerGestureScope> createState() =>
      _ImageViewerGestureScopeState();
}

class _ImageViewerGestureScopeState extends State<ImageViewerGestureScope> {
  final _pointers = <int>{};
  final _count = ValueNotifier(0);

  void _onDown(PointerDownEvent event) {
    _pointers.add(event.pointer);
    _count.value = _pointers.length;
  }

  void _onUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    _count.value = _pointers.length;
  }

  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _GalleryPointers(
    count: _count,
    child: Listener(
      onPointerDown: _onDown,
      onPointerUp: _onUp,
      onPointerCancel: _onUp,
      child: widget.child,
    ),
  );
}

class _GalleryPointers extends InheritedWidget {
  final ValueNotifier<int> count;

  const _GalleryPointers({required this.count, required super.child});

  @override
  bool updateShouldNotify(_GalleryPointers oldWidget) =>
      count != oldWidget.count;
}

/// Owns both image manipulation and the drag passed to a non-scrollable pager.
/// Only the horizontal distance left after panning reaches the image boundary
/// is passed to the pager, so the recognizers never compete for the same drag.
class ZoomableImage extends StatefulWidget {
  final Widget child;
  final PageController? pageController;
  final int pageIndex;
  final bool zoomEnabled;
  final Object? resetKey;
  final ValueChanged<ScaleEndDetails>? onInteractionEnd;

  const ZoomableImage({
    required this.child,
    this.pageController,
    this.pageIndex = 0,
    this.zoomEnabled = true,
    this.resetKey,
    this.onInteractionEnd,
    super.key,
  });

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage>
    with SingleTickerProviderStateMixin {
  static const _maxScale = 10.0;
  static const _doubleTapScale = 2.5;
  static const _scaleTolerance = 0.01;
  static const _animationDuration = Duration(milliseconds: 250);

  final _imageKey = GlobalKey();
  final _pointers = <int>{};
  ValueNotifier<int>? _galleryPointers;
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: _animationDuration,
  )..addListener(_animateTransform);
  double _scale = 1;
  double _startScale = 1;
  Offset _offset = Offset.zero;
  Offset _previousFocalPoint = Offset.zero;
  Offset _doubleTapPosition = Offset.zero;
  Size _viewport = Size.zero;
  bool _hadMultiplePointers = false;
  bool _horizontalDrag = false;
  bool _dragDirectionDecided = false;
  Offset _gestureDistance = Offset.zero;
  Drag? _pageDrag;
  double _pageDragDistance = 0;
  ScrollHoldController? _pageHold;
  double _animationStartScale = 1;
  double _animationEndScale = 1;
  Offset _animationStartOffset = Offset.zero;
  Offset _animationEndOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    widget.pageController?.addListener(_onPageMoved);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pointers = context
        .dependOnInheritedWidgetOfExactType<_GalleryPointers>()
        ?.count;
    if (pointers != _galleryPointers) {
      _galleryPointers?.removeListener(_onGalleryPointersChanged);
      _galleryPointers = pointers;
      pointers?.addListener(_onGalleryPointersChanged);
    }
  }

  void _onGalleryPointersChanged() {
    if (_galleryPointers!.value > 1 && _pointers.isNotEmpty) {
      _cancelPageForPinch();
    } else if (_galleryPointers!.value == 0) {
      _pageHold?.cancel();
      _pageHold = null;
    }
  }

  void _cancelPageForPinch() {
    _hadMultiplePointers = true;
    if (_pageDrag != null) {
      // jumpToPage also disposes the active drag without starting a fling.
      widget.pageController?.jumpToPage(widget.pageIndex);
      _pageDrag = null;
    }
  }

  @override
  void didUpdateWidget(covariant ZoomableImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageController != widget.pageController) {
      oldWidget.pageController?.removeListener(_onPageMoved);
      widget.pageController?.addListener(_onPageMoved);
    }
    if (oldWidget.resetKey != widget.resetKey) {
      _animation.stop();
      _scale = 1;
      _offset = Offset.zero;
    }
  }

  void _onPageMoved() {
    final page = widget.pageController?.page;
    // Reset an outgoing image only once it is completely off screen.
    if (page != null && (page - widget.pageIndex).abs() >= 1 && _scale != 1) {
      _animation.stop();
      setState(() {
        _scale = 1;
        _offset = Offset.zero;
      });
    }
  }

  Size get _imageSize {
    final box = _imageKey.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size : _viewport;
  }

  Offset _clampOffset(Offset offset, double scale) {
    final image = _imageSize;
    double clampAxis(double value, double viewport, double content) {
      if (content * scale <= viewport) return viewport * (1 - scale) / 2;
      final leading = (viewport - content) / 2 * scale;
      return value.clamp(viewport - leading - content * scale, -leading);
    }

    return Offset(
      clampAxis(offset.dx, _viewport.width, image.width),
      clampAxis(offset.dy, _viewport.height, image.height),
    );
  }

  void _animateTransform() {
    final t = Curves.easeOutCubic.transform(_animation.value);
    setState(() {
      _scale =
          _animationStartScale +
          (_animationEndScale - _animationStartScale) * t;
      _offset = Offset.lerp(_animationStartOffset, _animationEndOffset, t)!;
    });
  }

  void _animateTo(double scale, Offset offset) {
    _animationStartScale = _scale;
    _animationEndScale = scale;
    _animationStartOffset = _offset;
    _animationEndOffset = _clampOffset(offset, scale);
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() {
        _scale = scale;
        _offset = _animationEndOffset;
      });
    } else {
      _animation.forward(from: 0);
    }
  }

  void _onDoubleTap() {
    if (_scale > 1 + _scaleTolerance) {
      _animateTo(1, Offset.zero);
    } else {
      final scenePoint = (_doubleTapPosition - _offset) / _scale;
      _animateTo(
        _doubleTapScale,
        _doubleTapPosition - scenePoint * _doubleTapScale,
      );
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_pointers.isEmpty && (_galleryPointers?.value ?? 0) == 0) {
      _hadMultiplePointers = false;
      _animation.stop();
      final controller = widget.pageController;
      if (controller != null && controller.hasClients) {
        _pageHold = controller.position.hold(() => _pageHold = null);
      }
    }
    _pointers.add(event.pointer);
    if (_pointers.length > 1) {
      _cancelPageForPinch();
    }
  }

  void _onPointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.isEmpty && (_galleryPointers?.value ?? 0) <= 1) {
      _pageHold?.cancel();
      _pageHold = null;
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    _animation.stop();
    _startScale = _scale;
    _previousFocalPoint = details.localFocalPoint;
    _gestureDistance = Offset.zero;
    _horizontalDrag = false;
    _dragDirectionDecided = false;
  }

  void _dragPage(double delta, ScaleUpdateDetails details) {
    final controller = widget.pageController;
    if (controller == null || !controller.hasClients || delta == 0) return;
    if (_pageDrag == null) {
      _pageDragDistance = 0;
      _pageDrag = controller.position.drag(
        DragStartDetails(globalPosition: details.focalPoint),
        () => _pageDrag = null,
      );
    }
    _pageDragDistance += delta;
    _pageDrag!.update(
      DragUpdateDetails(
        delta: Offset(delta, 0),
        primaryDelta: delta,
        globalPosition: details.focalPoint,
        sourceTimeStamp: details.sourceTimeStamp,
      ),
    );
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount > 1 || details.scale != 1) {
      _hadMultiplePointers = true;
      if (!widget.zoomEnabled) return;
      final scale = (_startScale * details.scale).clamp(1.0, _maxScale);
      final scenePoint = (_previousFocalPoint - _offset) / _scale;
      setState(() {
        _scale = scale;
        _offset = _clampOffset(
          details.localFocalPoint - scenePoint * scale,
          scale,
        );
      });
      _previousFocalPoint = details.localFocalPoint;
      return;
    }

    final delta = details.focalPointDelta;
    _gestureDistance += delta;
    if (!_dragDirectionDecided && _gestureDistance.distance > kTouchSlop) {
      _dragDirectionDecided = true;
      _horizontalDrag = _gestureDistance.dx.abs() > _gestureDistance.dy.abs();
    }
    if (_pageDrag != null) {
      _dragPage(delta.dx, details);
      return;
    }
    final previous = _offset;
    final offset = _clampOffset(previous + delta, _scale);
    setState(() => _offset = offset);
    // A pinch remains an image gesture until every finger has lifted, even
    // when the image has been shrunk back to its fitted size.
    if (!_hadMultiplePointers && _horizontalDrag) {
      final remaining = delta.dx - (offset.dx - previous.dx);
      _dragPage(remaining, details);
    }
    _previousFocalPoint = details.localFocalPoint;
  }

  void _onScaleEnd(ScaleEndDetails details) {
    // Flutter ends/restarts the scale recognizer when its pointer count changes.
    if (details.pointerCount > 0) return;
    final pageDrag = _pageDrag;
    if (pageDrag != null) {
      _pageDrag = null;
      // Do not reuse a fast image pan's velocity when only a few pixels have
      // crossed the edge; that would accidentally fling to the next image.
      final velocity = _pageDragDistance.abs() > kTouchSlop * 2
          ? details.velocity.pixelsPerSecond.dx
          : 0.0;
      pageDrag.end(
        DragEndDetails(
          velocity: Velocity(pixelsPerSecond: Offset(velocity, 0)),
          primaryVelocity: velocity,
        ),
      );
    } else if (_scale > 1 + _scaleTolerance) {
      // Let a released image glide a little, clamped to its own boundaries.
      // Image momentum must never initiate a page transition.
      _animateTo(_scale, _offset + details.velocity.pixelsPerSecond * 0.15);
    } else if (!_hadMultiplePointers) {
      widget.onInteractionEnd?.call(details);
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !widget.zoomEnabled) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final scale = (_scale * math.exp(-event.scrollDelta.dy / 200)).clamp(
        1.0,
        _maxScale,
      );
      final scenePoint = (event.localPosition - _offset) / _scale;
      _animation.stop();
      setState(() {
        _scale = scale;
        _offset = _clampOffset(event.localPosition - scenePoint * scale, scale);
      });
    });
  }

  @override
  void dispose() {
    widget.pageController?.removeListener(_onPageMoved);
    _galleryPointers?.removeListener(_onGalleryPointersChanged);
    _animation.dispose();
    // ScrollPosition owns and disposes drag/hold activities. Starting a
    // ballistic scroll here is unsafe while the pager itself is unmounting.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final viewport = constraints.biggest;
      if (_viewport != viewport) {
        _animation.stop();
        _viewport = viewport;
        _scale = 1;
        _offset = Offset.zero;
      }
      return Listener(
        onPointerDown: _onPointerDown,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerUp,
        onPointerSignal: _onPointerSignal,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTapDown: widget.zoomEnabled
              ? (details) => _doubleTapPosition = details.localPosition
              : null,
          onDoubleTap: widget.zoomEnabled ? _onDoubleTap : null,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: ClipRect(
            child: Transform(
              transform: Matrix4.identity()
                ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                ..scaleByDouble(_scale, _scale, 1, 1),
              child: Center(
                child: KeyedSubtree(key: _imageKey, child: widget.child),
              ),
            ),
          ),
        ),
      );
    },
  );
}
