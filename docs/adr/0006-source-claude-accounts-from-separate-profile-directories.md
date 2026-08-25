# Source Claude accounts from a profile directory (or Keychain)

The predefined Claude slot connects to a user-selected Claude profile directory (or the current Keychain session for single-identity setups). After explicit consent, the app imports that profile's credentials into its slot-specific Keychain entry and watches the source for changes. The catalog is now five slots (Claude, GPT Personal, OpenCode GO, Command Code GOAT, Z.ai); the second Claude slot was removed — legacy `claude-legacy-1`/`claude-legacy-2` snapshots migrate to `claude`.

> Historical note: an earlier revision had two slots (Claude (legacy A) / Claude (legacy B)) with separate profile directories. Consolidated to one slot because a single `~/.claude` Keychain is the actual source for this user.
