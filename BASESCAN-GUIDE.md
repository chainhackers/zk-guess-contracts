# Basescan Manual Operations Guide

The frontend covers the happy path (create puzzle, guess, win). Functions like forfeit, claim, cancel, and withdraw must be called directly via Basescan.

## Prerequisites

1. Open the proxy contract on Basescan: [0xfa37cdcff862114c88c8e19b10b362d611a2c45f](https://basescan.org/address/0xfa37cdcff862114c88c8e19b10b362d611a2c45f#readProxyContract)
2. Click **Connect to Web3** to connect your wallet

## Reading State (Read tab)

### `getPuzzle(puzzleId)`

Returns the full puzzle struct. Key fields:

| Field | Meaning |
|---|---|
| `solved` | A guesser guessed correctly |
| `cancelled` | Creator cancelled the puzzle |
| `forfeited` | Creator stopped responding and puzzle was forfeited |
| `bounty` | Prize pool (fixed at 0.0001 ETH) |
| `collateral` | Creator's slashable deposit (any ETH sent above MIN_BOUNTY) |
| `pendingChallenges` | Number of unanswered guesses |
| `lastChallengeTimestamp` | When the most recent guess was submitted |
| `lastResponseTime` | When the creator last responded to any challenge |

### `getChallenge(puzzleId, challengeId)`

Returns a specific challenge. Check `responded` to see if the creator answered it.

### `balances(address)`

Check how much ETH is available for withdrawal. This accumulates from forfeit claims, solved-puzzle stake claims, and collateral returns.

### `RESPONSE_TIMEOUT()` / `CANCEL_TIMEOUT()`

Both return `86400` (1 day in seconds).

## Forfeit a Puzzle

When a puzzle creator stops responding to challenges, anyone can forfeit the puzzle.

**When allowed:** the creator hasn't responded within 24 hours. The clock starts from either:
- `lastResponseTime` — if the creator has responded to at least one challenge, or
- the timed-out challenge's `timestamp` — if the creator never responded

**How to call:**

1. Go to the **Write** tab
2. Find `forfeitPuzzle`
3. Enter:
   - `puzzleId` — the puzzle ID
   - `timedOutChallengeId` — any pending (unresponded) challenge ID for this puzzle
4. Submit the transaction

**What happens:**
- Puzzle is marked `forfeited`
- Collateral (if any) is slashed to the treasury
- Guessers with pending challenges can now claim their stake + bounty share

## Claim from Forfeited Puzzle

After a puzzle is forfeited, each guesser with pending challenges can claim their share.

**How to call:**

1. Go to the **Write** tab
2. Find `claimFromForfeited`
3. Enter the `puzzleId`
4. Submit the transaction

**What you receive** (credited to `balances`):
- Your full stake back
- A proportional share of the bounty: `bounty * yourPendingChallenges / totalPendingAtForfeit`

**Then call `withdraw()`** to receive the ETH (see below).

## Claim Stake from Solved Puzzle

When someone else won a puzzle, other guessers who had pending (unanswered) challenges get their stake back.

**How to call:**

1. Go to the **Write** tab
2. Find `claimStakeFromSolved`
3. Enter the `puzzleId`
4. Submit the transaction

**What you receive** (credited to `balances`):
- Your full pending stake back (no bounty share — that went to the winner)

**Then call `withdraw()`** to receive the ETH.

## Withdraw

Sends your full `balances` amount to your wallet.

**Before calling:** check `balances(yourAddress)` on the Read tab to confirm there's something to withdraw.

**How to call:**

1. Go to the **Write** tab
2. Find `withdraw`
3. Submit the transaction (no parameters needed)

## Cancel a Puzzle (Creator Only)

Creators can cancel their own puzzle to reclaim bounty + collateral.

**Requirements:**
- No pending challenges (`pendingChallenges` must be 0)
- Either no challenges were ever submitted, or `CANCEL_TIMEOUT` (1 day) has elapsed since the last challenge

**How to call:**

1. Go to the **Write** tab
2. Find `cancelPuzzle`
3. Enter the `puzzleId`
4. Submit the transaction

**What happens:**
- Bounty + collateral sent directly to creator (no `withdraw()` needed)
