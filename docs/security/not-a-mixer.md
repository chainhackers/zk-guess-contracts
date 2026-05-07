# Why zk-guess is not a mixer

This document is the canonical threat-model and non-mixer explainer for the zk-guess
protocol. The four-point summary below is the body submitted to Blockaid as part of the
`verifiedProject` filing; the rest of this document expands on each point.

## TL;DR (Blockaid submission body)

zk-guess is a number-guessing game using Groth16 to prove equality of two plaintext values
(committed secret = guessed number) while keeping the secret private. Unlike mixers:

1. **Every payout's recipient is fixed at deposit time** — `prize → challenge.guesser`,
   never user-supplied at withdrawal.
2. **Deposit→payout linkage is preserved in every event** (`puzzleId`, `challengeId`,
   `winner`, `amount`).
3. **Stakes are continuous, not fixed denominations** — there is no anonymity set.
4. **Economics are N-to-1** — many losing stakes fund one winner; the opposite of a
   mixer's 1-to-1 flow.

The forfeit mechanism, which activates if a creator is silent for 24 hours, generates
the unusual payout patterns a clustering heuristic may see; it's a deterministic state
machine with a public time guard, not discretionary routing.

## What clustering heuristics are reacting to

zk-guess's bytecode-level shape overlaps with Tornado-class mixers along legitimate
dimensions:

- A Groth16 verifier contract.
- `payable` deposits from many addresses.
- Payouts that "appear" after a proof is submitted.
- ETH-only flows; no ERC-20 wrapper.

A static analyzer cannot read the circuit, and so cannot distinguish "I know the
preimage of a commitment to a number" (zk-guess) from "I know the preimage of a Merkle
leaf" (mixer set-membership). The points below are what differs *structurally*, not at
the bytecode level.

## Point 1 — Recipient is fixed at deposit time, never user-supplied at withdrawal

Mixer property (Tornado-style): the depositor commits a secret note; at withdrawal time,
**any address** that can produce a valid proof of inclusion in the deposit set receives
the payout. The recipient is supplied as a public input to the proof and bound to a
fresh address.

zk-guess property: every payout's destination is a state variable set at deposit time,
not a user-supplied parameter at withdrawal:

| Payout | Recipient | Set when |
|---|---|---|
| Bounty + stakes (correct guess) | `puzzleChallenges[puzzleId][challengeId].guesser` | Deposit (`submitGuess`) |
| Stake refund (post-forfeit, per-guesser) | `msg.sender` (must be the original guesser) | Withdrawal call by the guesser themselves |
| Slashed creator collateral | `address treasury` (the Rewards contract, fixed at `initialize`) | Deploy time |
| Stale-bounty sweep (after 90 days unclaimed) | `address treasury` | Deploy time |
| Solved-puzzle stake refund | `msg.sender` (original guesser) | Withdrawal call by the guesser themselves |

There is no path in `GuessGame` or `Rewards` where a withdrawer supplies the recipient
of a payout that wasn't already linked to them by the protocol's own state.

## Point 2 — Deposit→payout linkage is preserved in every event

Each on-chain action emits an event with the identifiers needed to reconstruct the
deposit→payout edge in one query:

- `PuzzleCreated(puzzleId, creator, commitment, bounty, collateral, stakeRequired, maxNumber)`
- `ChallengeCreated(challengeId, puzzleId, guesser, guess, stake)`
- `PuzzleSolved(puzzleId indexed, challengeId indexed, winner, prize)` — winner is the
  guesser of `challengeId`; the indexed `challengeId` makes this trivially queryable.
- `ForfeitClaimed(puzzleId, guesser, amount)`
- `RewardsFunded(funder indexed, amount, purpose)` — every call-path inbound ETH to the
  rewards pool carries a labeled string purpose (`"forfeit-collateral-routing"`,
  `"stale-bounty-sweep"`, `"final-settlement-dust"`, or a donor-supplied label). There
  is no `receive()`/`fallback()` on `Rewards`, so plain ETH transfers revert and the
  only supported funding path is `fundRewards(purpose)`. Non-call balance changes
  (`SELFDESTRUCT`-forced ETH, pre-deploy address funding) cannot be prevented by any
  EVM contract; they are reconciled off-chain by the indexer.

Mixers deliberately break this linkage — that is the entire feature. zk-guess
deliberately preserves it.

## Point 3 — Continuous stakes, no fixed denominations, no anonymity set

Tornado pools have fixed denominations (0.1 / 1 / 10 / 100 ETH) precisely to maximize
the anonymity set. Two depositors of 1 ETH each become indistinguishable at withdrawal
time.

In zk-guess:

- `stakeRequired` is an arbitrary `uint256` set per-puzzle by the creator.
- Different puzzles have different stakes; different puzzles have different participant
  sets.
- Two players who happen to stake the same amount on different puzzles do not share an
  anonymity set — their funds flow through disjoint state slots.

There is no "pool" structure. Each puzzle is its own settlement.

## Point 4 — N-to-1 economics, opposite of a mixer's 1-to-1 flow

Mixer economics: each depositor of `N` ETH withdraws `N` ETH (minus fees and
anonymity-set jitter). 1-to-1 mass conservation is a feature.

zk-guess economics: many losing stakes fund one winner. A winning guess pays
`bounty + sum(all_stakes_on_this_puzzle) - creatorReward`, and the losing guessers'
stakes are absorbed (in part) into the bounty growth. This is the opposite of a mixer's
shape: many → one, with a deterministic split, not many → many with mass conservation.

## The forfeit mechanism (pre-disclosed)

The forfeit path is the most "unusual" payout pattern a clustering heuristic might see;
disclosed up-front:

1. If the creator does not respond to a pending challenge within `RESPONSE_TIMEOUT`
   (1 day), any address can call `forfeitPuzzle(puzzleId, challengeId)`. This is
   permissionless and time-gated.
2. On forfeit, the creator's collateral is routed to `Rewards` with the labeled
   `fundRewards("forfeit-collateral-routing")` call.
3. The bounty is split among the puzzle's pending guessers using a cumulative-divisor
   formula; each guesser claims their share + stake refund via
   `claimFromForfeited(puzzleId)`, which pays `msg.sender` based on that guesser's own
   pending challenges on the puzzle (no recipient parameter).
4. After `CLAIM_TIMEOUT` (90 days) of inactivity post-forfeit, any address can call
   `sweepStaleBounty(puzzleId)` to route the unclaimed remainder to `Rewards` with the
   labeled `fundRewards("stale-bounty-sweep")` call.
5. Once paused and every puzzle is terminal with frozen forfeit accounting,
   `settleNext(n)` and `settleAll()` walk a deterministic, auto-populated
   `_potentiallyOwed` queue. The owner cannot single out, omit, or reorder
   recipients.

Each step is permissionless or fully deterministic; no path lets the operator redirect
funds to a chosen address.

## Operator constraints (Phase B wallet topology)

Three distinct keypairs, none of which ever creates a puzzle, submits a guess, or claims
a reward. Documented per-address in [`wallet-topology.md`](./wallet-topology.md).

- **Deployer** — deploys the four contracts at v2 launch; may also deploy future `GuessGame` implementation contracts for UUPS upgrades. Never holds ownership; the operator (proxy owner) performs the `upgradeToAndCall` itself.
- **Funding** — receives ETH from a single, disclosed CEX withdrawal (exchange name and
  tx hash recorded in [`wallet-topology.md`](./wallet-topology.md) and the Blockaid
  filing); sends operator gas and fundRewards top-ups; never plays.
- **Operator** — owner of `GuessGame` proxy and `Rewards`; calls `pause`, `publishRoot`,
  `settleNext`/`settleAll`; never plays.

Operator wanting to play uses a separate, disclosed wallet, not linked to operator
funding.

## Reproducibility / verifiability anchors

- Source verified on Sourcify and Basescan for all four contracts (`GuessVerifier`,
  `Rewards`, `GuessGame` impl, `ERC1967Proxy`).
- Phase-2 trusted-setup ceremony for `circuits/guess.circom`, sealed 2026-04-28 by a
  Bitcoin-block beacon (block 947059, 2^10 iterations), with 5 human contributors
  ([@chainhacker](https://farcaster.xyz/chainhacker), [@darkliv](https://farcaster.xyz/darkliv),
  [@madco](https://farcaster.xyz/madco), [@codejedi](https://farcaster.xyz/codejedi),
  [@kinco](https://farcaster.xyz/kinco)). Per-contribution hashes, the final zkey, the
  `verification_key.json`, the per-contributor intermediate zkeys, and the
  `snarkjs zkey verify` output are all published at
  [`chainhackers/zk-guess-circuits/releases/tag/v2-ceremony`](https://github.com/chainhackers/zk-guess-circuits/releases/tag/v2-ceremony).
- The deployed `GuessVerifier` (Base mainnet `0x2772322a14Ff01c8df663AD13aaC3dC15aF1EfA9`)
  is the `GuessVerifier.sol` artifact attached to that release. Sourcify match against the
  ceremony release is the sufficient on-chain anchor — anyone can reproduce
  `snarkjs zkey verify generated/guess.r1cs generated/pot15_final.ptau guess_final.zkey`
  to confirm the verifying key.
- `ProjectMetadata` event emitted at `initialize` carries the canonical pointers:
  `homepage = "https://zk-guess.chainhackers.xyz"`, `circuitRepo` pointing at the
  `v2-ceremony` release URL, `vkeyChecksum` populated with the SHA-256 of
  `verification_key.json`
  (`2a0ae13d6d50943e65727831d614882463560b0c19ba789473b87b3c6ffc7179`), `auditUrl`
  blank pending the Phase G named-firm audit.

## Reputation pointers

- Farcaster mini-app listing: <!-- TODO: URL once submitted -->
- boost.xyz campaign: <!-- TODO: URL once active -->
- ENS pointer: `zkguess.chainhackers.eth` <!-- TODO: confirm registered -->
- Project homepage: https://zk-guess.chainhackers.xyz

## Bug bounty / disclosure

See [`SECURITY.md`](../../SECURITY.md) at the repo root for disclosure contact and bug
bounty terms.
