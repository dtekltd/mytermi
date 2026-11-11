# App Store review checklist

## What is already covered

| Guideline | How MyTermi meets it |
|---|---|
| **4.8 Login services.** Offering Google sign-in requires Sign in with Apple. | Sign in with Apple is available on iOS. Turn it on in the console (audience = bundle id) whenever Google is on. |
| **5.1.1(v) Account deletion.** Apps that support account creation must let users delete the account in the app. | **Settings → Account → Delete account** deletes the account and all synced data on the server. |
| **5.1.1(i/ii) Don't force a login for features that don't need an account.** | The SSH client works without an account; signing in is only for sync. |
| **2.1 Demo account.** | Create a reviewer account and put the credentials in App Review notes (see below). |

## Before submitting

1. **Production server over HTTPS**, reachable from Apple's network, with SMTP configured (see
   [deployment.md](deployment.md)). Build with `MYTERMI_API_URL=https://… ./run build ios` so the
   app points at it by default.
2. **Reviewer account.** Create an account through the app (email code), set a password, and give
   the reviewer the email and password. They can sign in with the password, with no inbox access
   needed. Also give them a test SSH server or tell them the app needs their own server; reviewers
   usually test with what you provide.
3. **Sign in with Apple capability.** Enable it on the App ID in the Apple Developer portal. The
   entitlement file is already in the project.
4. **Privacy policy URL** in App Store Connect. App Privacy answers:
   - Email address: collected, linked to the user, for app functionality (account).
   - The encrypted sync data is end-to-end encrypted. Per Apple's definitions, data the developer
     can't access in readable form is generally not "collected"; describe it accurately.
   - No tracking.
5. **Export compliance.** The app uses encryption (SSH, HTTPS, and the vault's
   XChaCha20-Poly1305 and Argon2id). All of it uses standard algorithms. Answer the encryption
   questions in App Store Connect accordingly and add `ITSAppUsesNonExemptEncryption` to
   `Info.plist` once you have confirmed your classification. If unsure, check Apple's export
   compliance docs.

## Paid plans (later)

Plans are currently assigned by admins only (no payments). If a paid plan unlocks features in the
iOS app, Apple requires **In-App Purchase** (guideline 3.1.1). Don't link to or mention an external
purchase page in the iOS app unless you qualify for an entitlement that allows it. Adding IAP means
App Store Server Notifications → server → plan change.

## Known gap: Apple token revocation

When a user who signed in with Apple deletes their account, Apple asks apps to revoke the user's
Apple tokens through the Sign in with Apple REST API. That needs a private key (.p8) from the
developer portal and the authorization code from sign-in. **This is not implemented yet**. The
account and data are deleted, but the Apple token isn't revoked. Plan to add it (server setting for
the .p8 key, plus revoking on `DELETE /me`) before or shortly after launch.
