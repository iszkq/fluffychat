// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/sign_in_flows/sign_in_method.dart';
import 'package:test/test.dart';

void main() {
  test(
    'password login wins over advertised OIDC and SSO for QR provisioning',
    () {
      expect(
        selectSignInMethod(
          signUp: false,
          supportsPassword: true,
          supportsOidc: true,
          supportsSso: true,
        ),
        SignInMethod.password,
      );
    },
  );

  test('legacy SSO cannot bypass an available app password login', () {
    expect(
      selectSignInMethod(
        signUp: false,
        supportsPassword: true,
        supportsOidc: false,
        supportsSso: true,
      ),
      SignInMethod.password,
    );
  });

  test(
    'servers without password login retain their supported browser flow',
    () {
      for (final oidc in [true, false]) {
        expect(
          selectSignInMethod(
            signUp: false,
            supportsPassword: false,
            supportsOidc: oidc,
            supportsSso: true,
          ),
          oidc ? SignInMethod.oidc : SignInMethod.sso,
        );
      }
    },
  );

  test(
    'registration retains OIDC or SSO even when password login is offered',
    () {
      for (final oidc in [true, false]) {
        expect(
          selectSignInMethod(
            signUp: true,
            supportsPassword: true,
            supportsOidc: oidc,
            supportsSso: true,
          ),
          oidc ? SignInMethod.oidc : SignInMethod.sso,
        );
      }
    },
  );

  test('password-only servers retain their app login', () {
    expect(
      selectSignInMethod(
        signUp: false,
        supportsPassword: true,
        supportsOidc: false,
        supportsSso: false,
      ),
      SignInMethod.password,
    );
  });
}
