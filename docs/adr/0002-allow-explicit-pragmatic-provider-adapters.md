# Allow explicit pragmatic provider adapters

Provider adapters will prefer official APIs but may use undocumented endpoints or import existing local sessions when no stable public usage API exists. Each adapter must make that dependency explicit and fail as unavailable or authentication-required rather than presenting uncertain data as valid; this trades some integration durability for support of the required subscriptions.
