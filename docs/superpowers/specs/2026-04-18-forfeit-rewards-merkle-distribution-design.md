# Forfeit Rewards: Merkle Distribution Design

**Date:** 2026-04-18
**Status:** Draft → ready for implementation plan
**Related:** PR #35 (scope extension)

## Context

The old `GuessGame` deployment sent creator collateral — slashed when creators fail to respond to challenges within `RESPONSE_TIMEOUT` — to a treasury EOA where it sat unused. For the fresh redeploy, we redirect this ETH into a rewards pool that funds streak bonuses and weekly leaderboards, rewarding consistent participation from guessers and creators.

The core `GuessGame` logic does not change. We introduce a separate `Rewards` contract whose address becomes `TREASURY_ADDRESS` at deploy time. Forfeit collateral flows into `Rewards`; an off-chain indexer computes eligibility weekly; the admin publishes merkle roots; users claim with proofs.

## Goals

- **Direct forfeit collateral to end users**, not to operator wallets.
- **Keep the rewards rules off-chain and flexible** — categories and weights evolve without contract changes.
- **Trust-minimized claims** — once a root is published, owner cannot change amounts or double-spend.
- **Small contract surface** — ~80 LoC, conventional patterns, easy to audit.
- **Ship in PR #35** since GuessGame's treasury is immutable post-initialize.

## Non-goals

- Designing the off-chain indexer itself (separate work item, different repo).
- Upgradeability of `Rewards` (non-upgradeable — replacement requires new GuessGame deployment, documented).
- Governance / DAO controls (owner is an EOA → Safe → future DAO, not in scope).
- Bug-bounty / manual grants budget (not funded from this pool).

## Architecture

```
┌──────────────┐   forfeit collateral    ┌─────────────┐
│  GuessGame   │ ──────────────────────▶ │   Rewards   │
└──────────────┘   via treasury address  └─────────────┘
                                                │
                                                │ receive()
                                                ▼
                                        address(this).balance
                                                │
┌──────────────┐                                │
│   Indexer    │ ── reads GuessGame events ─────┤
│  (off-chain) │                                │
└──────────────┘ ── publishRoot(root) ─────────▶│
                                                │
┌──────────────┐                                │
│    User      │ ── claim(epoch, amount, proof) ▶
└──────────────┘ ◀── ETH transfer via .call ────┘
```

**Contract boundaries:**

- `GuessGame` treats treasury as opaque — any address that accepts ETH. No knowledge of rewards logic.
- `Rewards` treats all incoming ETH as pool funds. No coupling to `GuessGame`. Generalises to donations, grants, external funding.
- Indexer is an off-chain codebase (likely a separate repo). Reads chain events, builds trees, hosts JSON.

## Contract: `Rewards.sol`

### State

```solidity
address public owner;                                       // Ownable
mapping(uint256 => bytes32) public roots;                   // epoch => merkle root
mapping(uint256 => mapping(address => bool)) public claimed;
uint256 public currentEpoch;                                // monotonic
```

### External

```solidity
receive() external payable;

function publishRoot(bytes32 root) external onlyOwner returns (uint256 epoch);

function claim(uint256 epoch, uint256 amount, bytes32[] calldata proof) external;

function transferOwnership(address newOwner) external onlyOwner;  // from OZ Ownable
function renounceOwnership() external onlyOwner;                  // from OZ Ownable
```

### Events

```solidity
event RootPublished(uint256 indexed epoch, bytes32 root);
event Claimed(uint256 indexed epoch, address indexed user, uint256 amount);
```

### Errors

```solidity
error InvalidRoot();
error EpochNotPublished();
error InvalidProof();
error AlreadyClaimed();
error TransferFailed();
```

### Leaf format

```solidity
bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(user, amount))));
```

Double-hashed to prevent second-preimage attacks between leaves and internal nodes. Convention matches OpenZeppelin `MerkleProof`.

### `publishRoot` implementation

```solidity
function publishRoot(bytes32 root) external onlyOwner returns (uint256 epoch) {
    if (root == bytes32(0)) revert InvalidRoot();
    epoch = ++currentEpoch;
    roots[epoch] = root;
    emit RootPublished(epoch, root);
}
```

- Monotonic epoch counter; no overwrite possible.
- No on-chain cadence enforcement — indexer decides weekly rhythm.

### `claim` implementation

```solidity
function claim(uint256 epoch, uint256 amount, bytes32[] calldata proof) external {
    if (claimed[epoch][msg.sender]) revert AlreadyClaimed();
    bytes32 root = roots[epoch];
    if (root == bytes32(0)) revert EpochNotPublished();

    bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))));
    if (!MerkleProof.verify(proof, root, leaf)) revert InvalidProof();

    claimed[epoch][msg.sender] = true;

    (bool ok,) = msg.sender.call{value: amount}("");
    if (!ok) revert TransferFailed();

    emit Claimed(epoch, msg.sender, amount);
}
```

Checks-effects-interactions: `claimed = true` set before transfer, blocks reentrancy.

### Admin model

- Initial owner = deployer (new `0x4c7A...`).
- Planned transfer: deployer → Gnosis Safe → future automation / DAO.
- No `pause`, no `emergencyWithdraw` — once ETH is in the pool, only a published root can release it.

### Bad-root recovery

No in-place correction (would break trust model). If a bad root is published:
- Issue a correction in the next epoch: indexer encodes `delta = ideal - over_distributed` per affected user as amounts in epoch N+1.
- For small errors, accept the loss and move on.

### Sunset / migration

Non-upgradeable by design. If `Rewards` needs replacement:
1. Owner stops publishing new epochs.
2. Users drain remaining pool via claims for published epochs.
3. Deploy new `Rewards` + new `GuessGame` (since `treasury` is immutable in GuessGame).
4. Old Rewards residue decays.

## Funding path (no code change to `GuessGame`)

`GuessGame.forfeitPuzzle` already does:

```solidity
(bool success,) = treasury.call{value: puzzle.collateral}("");
if (!success) revert TransferFailed();
```

Setting `TREASURY_ADDRESS = address(Rewards)` at initialize time auto-funds the pool on every forfeit. No modification to `GuessGame` required.

**Reentrancy:** `forfeitPuzzle` writes `forfeited = true` and `pendingAtForfeit = pendingChallenges` **before** the treasury call. Even with a hostile `receive()`, there's nothing to re-enter.

**Accounting:** `address(Rewards).balance` is the source of truth. No separate ledger of "forfeit-sourced vs donated" ETH needed.

## Off-chain reward categories (v1)

All rules live in indexer code, not in contracts. v1 scope:

| # | Category | Budget share | Eligibility (from events during epoch) |
|---|---|---|---|
| 1 | Active guesser streak | 30% | ≥1 `ChallengeCreated` on each of 7 days; ≥3 challenges total. Split equally among qualifiers. |
| 2 | Active creator streak | 20% | Created ≥1 puzzle AND zero `PuzzleForfeited` against them this epoch. Split equally. |
| 3 | Top 3 puzzle creators | 25% | Rank by `PuzzleCreated` count. 50/30/20 split. |
| 4 | Top 3 correct guessers | 25% | Rank by `PuzzleSolved` where `winner == user`. 50/30/20 split. |

**Epoch budget:** 50% of `address(Rewards).balance` at epoch close. Remaining 50% carries forward → unclaimed also carries forward naturally since it stays in balance.

**Skip threshold:** If pool < 0.01 ETH, skip the epoch (no root published).

**Deliberately out of v1:**
- Milestone / one-time awards
- Difficulty-weighted rewards
- Referrals
- Governance / bug-bounty budgets

## Epoch cadence

- Weekly, Monday 00:00 UTC alignment.
- First epoch begins the Monday after deployment.
- Root publishes 24–48h after epoch close (indexer + human review).
- No on-chain timestamp enforcement — owner publishes when ready, epoch counter is pure bookkeeping.
- Missed weeks are fine: next root publishes with a larger pool; users wait.

## Unclaimed handling

- No expiry — users can claim any published epoch anytime.
- Unclaimed ETH stays in `address(this).balance`, naturally feeding future epoch pools.
- Late joiners can't retroactively earn prior epochs but benefit from rollover in their active epochs.

## Deployment order (PR #35)

1. Deploy `Groth16Verifier`.
2. Deploy `Rewards` with `owner = deployer`.
3. Deploy `GuessGame` implementation.
4. Deploy `ERC1967Proxy` with `initialize(verifier, rewardsAddress, deployer)` — `rewardsAddress` becomes the immutable treasury.
5. Verify all three on Sourcify + Basescan.
6. Update README with addresses.
7. (Later) Transfer `Rewards` ownership to Safe.

`scripts/deploy-mainnet.sh` and `script/Deploy.s.sol` need to orchestrate this — either deploy `Rewards` inline and pass its address, or deploy separately and read from env. Details in the implementation plan.

## Test plan

### `test/Rewards.t.sol` (unit)

- `test_publishRoot_onlyOwner` — non-owner reverts with `OwnableUnauthorizedAccount`.
- `test_publishRoot_monotonicEpoch` — consecutive calls increment `currentEpoch`.
- `test_publishRoot_rejectsZeroRoot` — reverts with `InvalidRoot`.
- `test_publishRoot_emitsEvent`.
- `test_claim_succeedsWithValidProof` — transfers correct amount, marks claimed, emits event.
- `test_claim_revertsOnInvalidProof`.
- `test_claim_revertsOnDoubleClaim` — same (epoch, user) twice.
- `test_claim_revertsOnUnpublishedEpoch`.
- `test_claim_revertsOnInsufficientBalance` — pool smaller than amount.
- `test_receive_acceptsETH` — from any sender.
- `test_transferOwnership_works`.
- `test_renounceOwnership_works`.

### `test/RewardsIntegration.t.sol` (integration with GuessGame)

- Deploy `Verifier` + `Rewards` + `GuessGame` (treasury = Rewards).
- Creator with collateral, forfeit path → assert `Rewards.balance += collateral`.
- Build a 3-recipient merkle tree in-test, publish root, each user claims — assert balances + events.

### Scope deliberately excluded from contract tests

- Reward category rule correctness (streak / leaderboard logic) — lives in indexer repo.
- Merkle tree construction correctness — tested via in-test tree against OZ `MerkleProof.verify`.
- IPFS / JSON hosting.

## Files (PR #35 extension)

**New:**
- `src/Rewards.sol` — ~80 LoC contract.
- `test/Rewards.t.sol` — unit tests.
- `test/RewardsIntegration.t.sol` — GuessGame + Rewards integration.

**Modified:**
- `script/Deploy.s.sol` — deploy Rewards, pass its address as treasury.
- `scripts/deploy-mainnet.sh` — adjust for new deployment flow, print all addresses post-deploy.
- `README.md` — post-deploy: document new proxy / rewards addresses.

**Unchanged:**
- `src/GuessGame.sol` — no modifications; already calls `treasury.call{value: collateral}` on forfeit.
- `src/Settleable.sol`, `src/interfaces/*` — orthogonal.

## Implementation plan

Generated after this spec is approved. Next skill: `writing-plans`.
