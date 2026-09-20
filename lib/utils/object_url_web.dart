// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:web/web.dart' as web;

void revokeObjectUrl(String url) {
  if (url.startsWith('blob:')) web.URL.revokeObjectURL(url);
}
