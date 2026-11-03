// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/matrix.dart';

import 'sign_in_method.dart';

Future<({SignInMethod method, List<LoginFlow> flows})> discoverLoginMethod(
  Client client,
  Uri homeserver, {
  required bool signUp,
  required bool enableOidc,
}) async {
  final (_, _, flows, metadata) = await client.checkHomeserver(
    homeserver,
    fetchAuthMetadata: true,
  );
  return (
    method: selectSignInMethod(
      signUp: signUp,
      supportsPassword: flows.any((flow) => flow.type == 'm.login.password'),
      supportsOidc: metadata != null && enableOidc,
      supportsSso: flows.any((flow) => flow.type == 'm.login.sso'),
    ),
    flows: flows,
  );
}
