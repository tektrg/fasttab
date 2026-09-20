# Plan: add a retry to the upload step

## Context
The nightly upload fails when the network drops for a moment. We retry a few times before giving up.

## Steps
1. Wrap the upload call in a retry helper (3 attempts, 2s apart).
2. Log each attempt with its error.
3. Add a test that fails twice, then succeeds.

## Verification
- Run the unit tests.
- Unplug the network mid-upload and confirm it recovers.
