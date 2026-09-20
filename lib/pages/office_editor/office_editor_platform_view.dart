// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

export 'office_editor_platform_view_stub.dart'
    if (dart.library.io) 'office_editor_platform_view_native.dart'
    if (dart.library.js_interop) 'office_editor_platform_view_web.dart';
