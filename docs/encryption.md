# End-to-end encryption

Synced data is encrypted on the device before upload. The server, its database and its admins
cannot read hosts, SSH passwords, private keys or snippets. Code: `app/lib/services/vault_crypto.dart`.

## Keys

| Key | What | Where it lives |
|-----|------|----------------|
| **Vault key (VK)** | 32 random bytes; encrypts every item | Each unlocked device's Keychain/Keystore (`sync_vk`, this-device-only). Never sent in plaintext. |
| **Vault password** | Chosen by the user when enabling sync; separate from the login password (Apple/Google users have no login password) | Only in the user's head |
| **KEK** | Argon2id(vault password, salt) | Derived in memory, discarded |
| **Recovery key** | 20 random bytes, shown once as Crockford base32 `XXXX-XXXX-…` (8 groups of 4) | Written down by the user |
| **Recovery KEK** | HKDF-SHA256(recovery key, salt `mytermi-recovery-salt-v1`, info `mytermi-recovery-v1`) | Derived in memory |

### Algorithms

- **KDF:** Argon2id, m = 64 MiB, t = 3, p = 1, 32-byte output. The parameters are stored with the
  vault, so they can be raised later.
- **AEAD:** XChaCha20-Poly1305 with a random 24-byte nonce per encryption.
- **Sealed format:** `nonce (24) ‖ ciphertext ‖ tag (16)`.

The Dart Argon2id output was cross-checked against Go's `golang.org/x/crypto/argon2` for the same
inputs.

## What the server stores

```
vaults:      kdf params, salt, wrapped_key = seal(KEK, VK, aad="mytermi-vault-key-v1"),
             recovery_wrapped_key = seal(RecoveryKEK, VK, same aad), generation, rev
vault_items: id, type (host|key|snippet), rev, modified_at, deleted,
             data = seal(VK, JSON payload, aad="mytermi-item-v1:<type>:<id>")
```

The AAD binds each ciphertext to its item id and type. The server therefore can't swap two items
or replay one item under another id without decryption failing.

### Payloads (plaintext, before encryption)

| Type | Fields |
|------|--------|
| `host` | label, hostname, port, username, auth method, key id, SSH password |
| `key` | label, type, public key, fingerprint, PEM private key, passphrase |
| `snippet` | name, command, auto-run |

## What the server can see

- The account email, sign-in methods, and plan.
- How many items of each type exist, item sizes, and when items change (`modified_at`, revisions).
- The KDF parameters and salt.
- IP addresses and device names of sessions.

Password guessing is possible only offline: someone with a copy of the database could try vault
passwords against `wrapped_key`, slowed down by Argon2id. Use a strong vault password; the app
requires at least 8 characters.

## Flows

| Flow | What happens |
|------|--------------|
| **Enable sync** (first device) | Generate VK, salt and recovery key. Wrap VK twice. `POST /vault`. Keep VK in the Keychain. Show the recovery key once. |
| **New device** | `GET /vault`, derive the KEK from the vault password, open `wrapped_key` to get VK, keep VK. A wrong password fails AEAD authentication. |
| **Change vault password** | Re-wrap the same VK with a new salt and KEK (`PUT /vault` with the current generation). Items are not re-encrypted. Other devices keep working. |
| **Forgot vault password** | Open `recovery_wrapped_key` with the recovery key, then re-wrap with a new password. |
| **Forgot both** | `DELETE /vault` wipes the vault and all items. A new vault (new VK, new generation) is created from this device's local data. Other devices must unlock again; data that existed only on them is not merged. |
| **Sign out** | Delete VK and sync state from the device. Local hosts, keys and snippets stay. |
| **Delete account** | The server deletes the user, sessions, vault and items (cascade). |

## Transport

Use HTTPS in production (see [deployment.md](deployment.md)). The iOS app allows plain HTTP only
to local-network addresses (`NSAllowsLocalNetworking`), and Android only in debug builds.
