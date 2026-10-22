// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/widgets/zoomable_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Future<PageController> _gallery(
  WidgetTester tester, {
  int initialPage = 0,
  Size imageSize = const Size(400, 200),
  VoidCallback? onTap,
  bool zoomEnabled = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = PageController(initialPage: initialPage);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: GestureDetector(
        onTap: onTap,
        child: ImageViewerGestureScope(
          child: PageView.builder(
            controller: controller,
            physics: const NeverScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            itemCount: 3,
            itemBuilder: (context, index) => ZoomableImage(
              key: ValueKey(index),
              pageController: controller,
              pageIndex: index,
              zoomEnabled: zoomEnabled,
              child: GestureDetector(
                onTap: () {},
                child: SizedBox.fromSize(
                  size: imageSize,
                  child: ColoredBox(color: Colors.primaries[index]),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return controller;
}

Matrix4 _transform(WidgetTester tester, [int index = 0]) => tester
    .widget<Transform>(
      find
          .descendant(
            of: find.byKey(ValueKey(index)),
            matching: find.byType(Transform),
          )
          .first,
    )
    .transform;

Future<void> _doubleTap(
  WidgetTester tester, [
  Offset position = const Offset(200, 400),
]) async {
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tapAt(position);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('double tap zooms around the tap and restores without closing', (
    tester,
  ) async {
    var closed = false;
    await _gallery(tester, onTap: () => closed = true);
    await _doubleTap(tester, const Offset(300, 400));
    expect(_transform(tester).getMaxScaleOnAxis(), 2.5);
    expect(_transform(tester).entry(0, 3), -450);
    expect(closed, isFalse);
    await _doubleTap(tester);
    expect(_transform(tester), Matrix4.identity());
    expect(closed, isFalse);
  });

  testWidgets('a fitted image can swipe to the next page', (tester) async {
    final controller = await _gallery(tester);
    await tester.dragFrom(const Offset(350, 400), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(controller.page, 1);
  });

  testWidgets('panning within a zoomed image never moves the pager', (
    tester,
  ) async {
    final controller = await _gallery(tester);
    await _doubleTap(tester);
    final gesture = await tester.startGesture(const Offset(250, 400));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump();
    expect(controller.page, 0);
    expect(_transform(tester).entry(0, 3), lessThan(-300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.page, 0);
  });

  testWidgets('the same drag pans to the edge then reveals and changes page', (
    tester,
  ) async {
    final controller = await _gallery(tester);
    await _doubleTap(tester);
    final gesture = await tester.startGesture(const Offset(350, 400));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-280, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(controller.page, 0);
    expect(_transform(tester).getMaxScaleOnAxis(), 2.5);
    await gesture.moveBy(const Offset(-220, 0));
    // Once the image is at its edge, crossing the handoff distance starts the
    // pager while preserving the same continuous drag.
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(controller.page, greaterThan(0));
    expect(controller.page, lessThan(0.5));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.page, 1);
    expect(_transform(tester, 1), Matrix4.identity());
  });

  testWidgets('a short edge drag stays on the same zoomed image', (
    tester,
  ) async {
    final controller = await _gallery(tester);
    await _doubleTap(tester);
    final gesture = await tester.startGesture(const Offset(350, 400));
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-340, 0));
    await tester.pump();
    // Reaching the image edge alone must not start paging. The gesture needs
    // to continue past the deliberate handoff distance first.
    expect(controller.page, 0);
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.page, 0);
    expect(_transform(tester).getMaxScaleOnAxis(), 2.5);
  });

  testWidgets('an inward drag at the edge pans instead of paging', (
    tester,
  ) async {
    final controller = await _gallery(tester, initialPage: 1);
    await _doubleTap(tester);
    final outward = await tester.startGesture(const Offset(200, 400));
    await outward.moveBy(const Offset(30, 0));
    await tester.pump();
    await outward.moveBy(const Offset(280, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await outward.up();
    await tester.pumpAndSettle();
    final inward = await tester.startGesture(const Offset(250, 400));
    await inward.moveBy(const Offset(-30, 0));
    await tester.pump();
    await inward.moveBy(const Offset(-100, 0));
    await tester.pump();
    expect(controller.page, 1);
    expect(_transform(tester, 1).entry(0, 3), lessThan(0));
    await inward.up();
    await tester.pumpAndSettle();
  });

  testWidgets('pinch followed by one finger stays locked to the image', (
    tester,
  ) async {
    final controller = await _gallery(tester);
    final left = await tester.startGesture(const Offset(100, 400), pointer: 1);
    final right = await tester.startGesture(const Offset(300, 400), pointer: 2);
    await left.moveBy(const Offset(-80, 0));
    await right.moveBy(const Offset(80, 0));
    await tester.pump();
    await left.moveBy(const Offset(-40, 0));
    await right.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(_transform(tester).getMaxScaleOnAxis(), greaterThan(1));
    await right.up();
    await left.moveBy(const Offset(-500, 0));
    await tester.pump();
    await left.moveBy(const Offset(-500, 0));
    await tester.pump();
    expect(controller.page, 0);
    await left.up();
    await tester.pumpAndSettle();
    expect(controller.page, 0);
  });

  testWidgets('portrait image uses its real horizontal boundary', (
    tester,
  ) async {
    final controller = await _gallery(tester, imageSize: const Size(100, 800));
    await _doubleTap(tester);
    // Even enlarged this narrow image is smaller than the viewport width.
    await tester.dragFrom(const Offset(350, 400), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(controller.page, 1);
  });

  testWidgets('leaving a page resets zoom before it is visited again', (
    tester,
  ) async {
    final controller = await _gallery(tester);
    await _doubleTap(tester);
    controller.nextPage(
      duration: const Duration(milliseconds: 1),
      curve: Curves.linear,
    );
    await tester.pumpAndSettle();
    controller.jumpToPage(0);
    await tester.pumpAndSettle();
    expect(_transform(tester), Matrix4.identity());
  });

  testWidgets('mouse wheel zoom remains available', (tester) async {
    await _gallery(tester);
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(200, 400),
        scrollDelta: Offset(0, -100),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pumpAndSettle();
    expect(_transform(tester).getMaxScaleOnAxis(), greaterThan(1));
  });

  testWidgets(
    'a fast image pan barely crossing the edge does not fling pages',
    (tester) async {
      final controller = await _gallery(tester);
      await _doubleTap(tester);
      final gesture = await tester.startGesture(const Offset(350, 400));
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 10));
      await gesture.moveBy(const Offset(-280, 0));
      await tester.pump(const Duration(milliseconds: 10));
      await gesture.moveBy(const Offset(-10, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.page, 0);
      expect(_transform(tester).getMaxScaleOnAxis(), 2.5);
    },
  );

  testWidgets('zooming out to fit keeps paging locked until all fingers lift', (
    tester,
  ) async {
    final controller = await _gallery(tester);
    await _doubleTap(tester);
    final left = await tester.startGesture(const Offset(50, 400), pointer: 1);
    final right = await tester.startGesture(const Offset(350, 400), pointer: 2);
    await left.moveBy(const Offset(50, 0));
    await right.moveBy(const Offset(-50, 0));
    await tester.pump();
    await left.moveBy(const Offset(80, 0));
    await right.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(_transform(tester).getMaxScaleOnAxis(), 1);
    await right.up();
    await left.moveBy(const Offset(-50, 0));
    await tester.pump();
    await left.moveBy(const Offset(-350, 0));
    await tester.pump();
    await left.up();
    await tester.pumpAndSettle();
    expect(controller.page, 0);
    await tester.dragFrom(const Offset(350, 400), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(controller.page, 1);
  });

  testWidgets('adding a second finger cancels an incomplete page drag', (
    tester,
  ) async {
    final controller = await _gallery(tester);
    final left = await tester.startGesture(const Offset(350, 400), pointer: 1);
    await left.moveBy(const Offset(-50, 0));
    await tester.pump();
    await left.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(controller.page, greaterThan(0));
    final right = await tester.startGesture(const Offset(300, 400), pointer: 2);
    await tester.pump();
    expect(controller.page, 0);
    await left.moveBy(const Offset(-30, 0));
    await right.moveBy(const Offset(30, 0));
    await tester.pump();
    await right.up();
    await left.moveBy(const Offset(-400, 0));
    await tester.pump();
    await left.up();
    await tester.pumpAndSettle();
    expect(controller.page, 0);
  });

  testWidgets('video pages retain taps and swiping without image zoom', (
    tester,
  ) async {
    var closed = false;
    final controller = await _gallery(
      tester,
      zoomEnabled: false,
      onTap: () => closed = true,
    );
    await _doubleTap(tester);
    expect(_transform(tester), Matrix4.identity());
    expect(closed, isFalse);
    await tester.dragFrom(const Offset(350, 400), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(controller.page, 1);
  });

  testWidgets('zoom and restore also work without a pager', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ZoomableImage(
          key: ValueKey(0),
          child: SizedBox(width: 400, height: 200),
        ),
      ),
    );
    await _doubleTap(tester);
    expect(_transform(tester).getMaxScaleOnAxis(), 2.5);
    await tester.dragFrom(const Offset(250, 400), const Offset(-800, 0));
    await tester.pumpAndSettle();
    await _doubleTap(tester);
    expect(_transform(tester), Matrix4.identity());
  });

  testWidgets('a zoomed image can pan to the previous page', (tester) async {
    final controller = await _gallery(tester, initialPage: 1);
    await _doubleTap(tester);
    final gesture = await tester.startGesture(const Offset(50, 400));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.page, 0);
  });
}
