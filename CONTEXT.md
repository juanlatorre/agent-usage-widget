# Agent Usage

This context describes normalized subscription-capacity information used to decide whether an AI provider account can be used now.

## Language

**Provider**:
An integration that obtains subscription usage for one AI service and normalizes it into usage snapshots.

**Account**:
One imported subscription identity belonging to a provider.

**Imported Profile**:
A supported local tool identity explicitly selected as the credential source for an account slot.

**Account Slot**:
A predefined provider-and-label position that the user connects to one compatible imported profile.
_Avoid_: Dynamically created account

**Usage Window**:
A provider-reported capacity limit over a reset period, such as five hours, weekly, or monthly.

**Blocking Window**:
A required usage window with no remaining capacity, preventing its account from being used.

**Effective Availability**:
Whether an account can be used now after considering every required usage window.
_Avoid_: Overall status, provider health

**Limiting Window**:
The required usage window with the least remaining proportional capacity; it supplies the account's representative percentage without replacing effective-availability logic.

**Usage Snapshot**:
The normalized usage state for one account at a recorded point in time, including its windows and effective availability.

**Available At**:
The earliest known time when every currently blocking window has reset.
_Avoid_: First reset
