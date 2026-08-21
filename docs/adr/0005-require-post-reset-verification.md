# Require post-reset verification

Crossing a cached window's reset time triggers an immediate refresh but does not locally convert a blocked account to available. Until a successful post-reset snapshot arrives, the UI presents a non-availability state with the previous snapshot as historical context, avoiding a false availability claim when server state or reset timing has changed.
