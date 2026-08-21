# Synchronize selected profiles into Keychain

The app detects only non-secret metadata until the user explicitly connects a local profile. After consent, it copies the selected credentials into macOS Keychain and updates that Keychain copy when the source profile changes; provider requests never depend on widget-accessible secrets or app-owned plaintext credential files.
