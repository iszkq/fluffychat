// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

enum SignInMethod { password, oidc, sso }

SignInMethod selectSignInMethod({
  required bool signUp,
  required bool supportsPassword,
  required bool supportsOidc,
  required bool supportsSso,
}) {
  // Browser authorization never exposes the password to this client. Use
  // password login when offered so successful login can provision QR login.
  if (!signUp && supportsPassword) return SignInMethod.password;
  if (supportsOidc) return SignInMethod.oidc;
  if (supportsSso) return SignInMethod.sso;
  return SignInMethod.password;
}
