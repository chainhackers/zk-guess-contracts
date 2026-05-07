# Anti-Mixer Redeploy — As Built

**Status:** Shipped 2026-05-05 to Base mainnet (block 45605232).
**Issue:** [#39](https://github.com/chainhackers/zk-guess-contracts/issues/39) (umbrella tracker for the v2 redeploy).
**Related PRs:** #41 (C0 v2 circuit wiring) · #42 (this doc — original
pre-implementation draft, since superseded by the contents below) · #43
(Phase C contract hardening) · #44 (Phase B/D wallet topology + deploy
script + v2 deploy).
**Original draft:** preserved in git history at commits `6ca5bc9` (created
2026-04-26) and `b9af930` (PR #42 review revision). Read that for the
pre-implementation perspective; this document reflects what actually shipped.

## Context

The v1 zk-guess deployment on Base mainnet drew Blockaid clustering attention
because its bytecode-level shape (Groth16 verifier + payable deposits +
ETH-only flows) overlaps with Tornado-class mixers. A file-by-file review
confirmed the protocol is **structurally non-mixer** — payout recipients are
fixed at deposit time, deposit→payout linkage is preserved in events, no
set-membership proofs, variable denominations, N-to-1 economics. The clustering
hit was driven by two things a static analyzer can read but the circuit
semantics it cannot: (a) on-chain signals were insufficiently legible —
unlabeled `treasury.call{value:...}("")` wires and a bare `Rewards.receive()`
that accepted any ETH; (b) the deployer/owner/funding/playtest graph was
monolithic (a single EOA `0x4c7AE65565a8DF70cbAB1b8a504c56E39da59B7A`).

v2 redeploys the entire stack from a fresh deployer with hardened code, a
three-role wallet split, a regenerated verifier from a public phase-2
ceremony, and labeled event coverage. v1 had 3 puzzles / 0 challenges
lifetime, so migration is a one-shot `settleAll` (Phase F, still pending at
the time of this writing).

## Deployed contracts (Base mainnet)

| Contract           | Address                                                                                                                       | Deploy tx                                                                                                                              |
|--------------------|-------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------|
| GuessGame proxy    | [`0xbA14152f40Df6673f316FD623313377Df6edD88A`](https://basescan.org/address/0xbA14152f40Df6673f316FD623313377Df6edD88A)        | [`0x1aec873d…`](https://basescan.org/tx/0x1aec873dc1a07fce5b7080dfd4d63af426b9dcc6a5559dd978d6bd58d0c3d264)                              |
| GuessGame impl     | [`0xe9813127Fc5927289966DDBe1B0c36bC5190E0F4`](https://basescan.org/address/0xe9813127Fc5927289966DDBe1B0c36bC5190E0F4)        | [`0x3fee9e89…`](https://basescan.org/tx/0x3fee9e89977b16dc9e2d9be1f993640d56f526fee7859e5d6ee15d6f1323602c)                              |
| Verifier (Groth16) | [`0xC6AACD8eAe397a92fA2175Dd0938e3A9c4f3582C`](https://basescan.org/address/0xC6AACD8eAe397a92fA2175Dd0938e3A9c4f3582C)        | [`0xdf65019a…`](https://basescan.org/tx/0xdf65019ab799bebeb08dd00f91334273ec0e9215106b029fa2f510db200ab780)                              |
| Rewards            | [`0x594A8b4fA394580f02c8C7B6450Fa5859F9b602F`](https://basescan.org/address/0x594A8b4fA394580f02c8C7B6450Fa5859F9b602F)        | [`0x46444866…`](https://basescan.org/tx/0x4644486635022aa671b2cfef3f615624c098706fb4a952c116ba2c05c595061b)                              |

All four contracts verified on Sourcify and Basescan during the deploy run
(`forge script ... --verify --verifier sourcify` plus a post-deploy Basescan
verification pass).

## Wallet roles (three-role separation)

| Role     | Address                                                                                                                       | Constraint                                                                                                          |
|----------|-------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------|
| Deployer | [`0x5A089E9Ca9AB8259d024CFBEe697B975cAea861d`](https://basescan.org/address/0x5A089E9Ca9AB8259d024CFBEe697B975cAea861d)        | Deploys contracts; **never** holds ownership; retained for future impl redeploys (UUPS upgrades), not retired.       |
| Funding  | [`0x0eE9931E50aaD6fB6Fb42BB61B8c2fCA6d757865`](https://basescan.org/address/0x0eE9931E50aaD6fB6Fb42BB61B8c2fCA6d757865)        | Single KuCoin withdrawal as inbound source; funds deployer, operator, and boost.xyz incentive campaigns; never plays. |
| Operator | [`0xa3369e05999eC082f54817a0a991916780F8bdC4`](https://basescan.org/address/0xa3369e05999eC082f54817a0a991916780F8bdC4)        | `owner()` of `GuessGame` proxy and `Rewards`; calls `pause`, `publishRoot`, `settleNext`, `settleAll`; never plays.   |

Full per-address provenance graph (KuCoin → funding → deployer/operator with
all transaction hashes) is in
[`docs/security/wallet-topology.md`](../../security/wallet-topology.md).

## Phase A — Circuit v2 (`chainhackers/zk-guess-circuits`)

Four circuit changes shipped via circuits#9, each on top of v1 (`Poseidon([number, salt])` commitment, public signals `[commitment, isCorrect, guess, maxNumber]`):

1. **Bind `puzzleId`** as a public input — prevents proof replay across puzzles that happen to share a commitment.
2. **Bind `guesser`** address — prevents a third party front-running someone else's proof submission.
3. **Range-check `guess`** in-circuit (`1 ≤ guess ≤ maxNumber`) — game well-formedness is now proof-layer-guaranteed instead of UI-trusted.
4. **Domain-separate the commitment** via `Poseidon([DOMAIN_TAG, number, salt])` where `DOMAIN_TAG = keccak256("zkguess.v2") mod p(BN254)`. v1 commitments cannot collide with v2 under any future composition.

Final v2 public signals: `[commitment, isCorrect, guess, maxNumber, puzzleId, guesser]` (6 entries).

The verifier was regenerated from a phase-2 trusted-setup ceremony, sealed
2026-04-28 by Bitcoin block 947059 (2¹⁰ iterations) with 5 human contributors
([@chainhacker](https://farcaster.xyz/chainhacker),
[@darkliv](https://farcaster.xyz/darkliv),
[@madco](https://farcaster.xyz/madco),
[@codejedi](https://farcaster.xyz/codejedi),
[@kinco](https://farcaster.xyz/kinco)). Per-contribution hashes, the final
zkey, the per-contributor intermediate zkeys, the `verification_key.json`, and
the `snarkjs zkey verify` output are all published as
[`v2-ceremony`](https://github.com/chainhackers/zk-guess-circuits/releases/tag/v2-ceremony).

**Divergence from original draft:** the release tag is `v2-ceremony`, not the
originally-planned `v2.0.0`. The on-chain `ProjectMetadata` event emitted at
`initialize` (Phase C7 below) still carries the stale `circuitRepo=v2.0.0`
URL pointing at the non-existent tag — to be corrected in the next impl
upgrade.

## Phase B — Wallet topology

Three keypairs generated 2026-05-03; funded 2026-05-05 from a single 0.05 ETH
KuCoin withdrawal (`0x2bdb477c…`). The deploy script (`script/Deploy.s.sol`)
enforces the three-role separation in code, not just operationally:

- Reads `OWNER` and `DEPLOYER_ADDRESS` from env.
- `require(owner != deployer, "Deploy: OWNER must differ from DEPLOYER_ADDRESS")`.
- `vm.startBroadcast(deployer)` — Foundry refuses to broadcast unless the loaded keystore matches the env-supplied deployer address, catching misconfigured `--keystore`/`--account`/`--private-key` flags loudly at runtime.

**Divergence from original draft:** owner is passed directly to the `Rewards`
constructor and `GuessGame.initialize`, so the deployer EOA never holds
ownership at any point. The originally-planned post-deploy
`transferOwnership(operator)` call is unnecessary and not used.

**Divergence from original draft:** funding source is KuCoin, not Coinbase
or Kraken — the latter two don't operate in the operator's jurisdiction
(Russia). Disclosure principle ("named, regulated CEX, single hop, no DEX
swaps, no contract intermediaries on the inbound path") is preserved.

## Phase C — Contract hardening

| # | Change | PR |
|---|---|---|
| **C0** | v2 circuit wiring: `respondToChallenge` takes `uint256[6]` pubSignals and validates `_pubSignals[4] == puzzleId` + `_pubSignals[5] == uint160(guesser)` before the `verifyProof` pairing call (saves ~200k gas on malformed/replayed submissions). | #41 |
| **C1 + C2** | Removed `Rewards.receive()` and `fallback()`; gated funding through `fundRewards(string purpose) external payable` emitting `RewardsFunded(funder, amount, purpose)`. `GuessGame.forfeitPuzzle` routes collateral via `fundRewards("forfeit-collateral-routing")`. | #43 |
| **C3** | `sweepStaleBounty(puzzleId)` permissionless after `RESPONSE_TIMEOUT + CLAIM_TIMEOUT` (1 day + 90 days); routes unclaimed bounty to `Rewards` via `fundRewards("stale-bounty-sweep")`. | #43 |
| **C4** | `PuzzleSolved` adds indexed `challengeId`. `ForfeitClaimed` already carried `amount` from v1. | #43 |
| **C5** | Queue-based settlement: `EnumerableSet _potentiallyOwed` auto-populated on every user interaction, `settleNext(n, reason)` + `settleAll(reason)` + `canSettle()` precondition (paused + every puzzle terminal + claim windows elapsed). Owner cannot single out, omit, or reorder recipients. | #43, #44 |
| **C6** | NatSpec coverage: `@title`, `@notice`, `@custom:security-contact`, `@custom:circuit-repo`, `@custom:homepage`, `@custom:commitment-domain`, plus post-Cancun SELFDESTRUCT-aware wording on `Rewards`. | #43, #44 |
| **C7** | `ProjectMetadata(homepage, circuitRepo, vkeyChecksum, auditUrl)` one-shot event emitted at `initialize`. | #43 |

**C5 divergence — `MAX_DUST` cap.** PR #43 added a `MAX_DUST = 10000`
defense-in-depth cap in `settleAll`: if residual contract balance exceeded
the cap, finalization reverted with `ExcessiveDust(amount)`. PR #44 round-2
review **removed** the cap. On Cancun an attacker can force ETH into any
contract via `SELFDESTRUCT` (EIP-6780 nerfs deletion but still routes the
value transfer); pushing dust above the cap for ~10001 wei + gas would have
permanently bricked finalization. Liveness > bug detection. The post-route
`BalanceMismatch` check still proves correctness (balance must be 0 after
the route); the `dust` field on the `Settled` event lets indexers flag
unusually large amounts for off-chain reconciliation.

**C7 known gap.** The launch deploy emitted `ProjectMetadata` with blank
`vkeyChecksum`, blank `auditUrl`, and a stale `circuitRepo=v2.0.0` URL
(pointing at a non-existent tag — the actual ceremony release is
`v2-ceremony`). Off-chain readers should treat
[`docs/security/not-a-mixer.md`](../../security/not-a-mixer.md) and
[`SECURITY.md`](../../../SECURITY.md) as the canonical pointers. To be
corrected in the next impl upgrade.

## Phase D — Deploy / verify / submit

Deployed 2026-05-05, block 45605232 (per-contract tx hashes in the deployed
addresses table above). All four contracts verified on Sourcify + Basescan
during the deploy script.

**Pending sub-items** (tracked on issue #39):

- Blockaid `verifiedProject` filing at <https://report.blockaid.io/verifiedProject>. Submission body is the TL;DR section of [`docs/security/not-a-mixer.md`](../../security/not-a-mixer.md).
- Basescan name-tag "ZK Guess Game" submission for the proxy.
- ENS registration `zkguess.chainhackers.eth` → proxy.

**Divergence from original draft:** the originally-considered
`script/DeployDeterministic.s.sol` (CREATE2 with a custom salt) was not
pursued — vanity addresses are not a meaningful mixer-defense signal and the
extra script surface wasn't worth carrying. v2 uses regular `CREATE`.

## Phase E — Documentation

- [`SECURITY.md`](../../../SECURITY.md) — disclosure contact, bug-bounty terms, role disclosure (incl. historical v1 monolithic EOA), upgradeability policy, post-Cancun SELFDESTRUCT-aware NatSpec, address registry pointers.
- [`docs/security/not-a-mixer.md`](../../security/not-a-mixer.md) — canonical four-point Blockaid-submission threat model (recipient fixed at deposit, deposit→payout linkage in events, continuous stakes / no anonymity set, N-to-1 economics) + reproducibility anchors (Sourcify match against the `v2-ceremony` release).
- [`docs/security/wallet-topology.md`](../../security/wallet-topology.md) — three-role design, full per-address funding provenance, audit subgraph queries.
- This document.

## Phase F — Migration (pending)

- v1 `settleAll(address[], "migration-to-v2-antimixer")` on
  [`0xa05ebcf0…`](https://basescan.org/address/0xa05ebcf0f9aab5194c8a3ec8571a1d85d0a7f590)
  with the 3 v1 puzzle creators. v1 contract seals (`settled = true`).
- Frontend (`zk-guess` repo) switches `VITE_GAME_ADDRESS` +
  `VITE_REWARDS_ADDRESS` + commitment `DOMAIN_TAG` to v2 values.
- Indexer (`zk-guess-indexer` repo) redeployed against v2 addresses; v1
  indexer archived.

## Phase G — Deferred (tracked, not blocking)

- Safe multisig for operator (revisit once v2 is stable).
- Named-firm audit engagement.
- GitHub Pages on `chainhackers/zk-guess-rewards` (blocked on
  private-repo + free-plan decision).

## Locked decisions (delta from the 2026-04-23 draft)

1. **Init-time owner**, not post-deploy `transferOwnership(operator)`.
   Deployer EOA never holds ownership at any point.
2. **Deployer keypair retained** for future impl redeploys (UUPS upgrades),
   not retired after the v2 launch tx batch.
3. **KuCoin** as funding-source CEX (regional access; Coinbase/Kraken don't
   operate in Russia). Disclosure principle preserved.
4. **Release tag `v2-ceremony`**, not `v2.0.0`. On-chain `ProjectMetadata`
   still references the stale `v2.0.0` URL — to be fixed in the next impl
   upgrade.
5. **No CREATE2 / `DeployDeterministic.s.sol`.** Vanity addresses are not a
   meaningful mixer-defense signal.
6. **`MAX_DUST` cap dropped** after PR #44 round-2 review (SELFDESTRUCT
   griefing of finalization). See Phase C5 above.
7. **Three-role separation enforced in code**
   (`vm.startBroadcast(deployer)` + `OWNER != DEPLOYER` require), not just
   operationally.
8. **v1 cutover deferred** to a separate PR (Phase F). v2 contracts are live
   independently of v1 sealing.

## References

- [`docs/security/wallet-topology.md`](../../security/wallet-topology.md) — full per-address provenance + audit subgraph queries.
- [`docs/security/not-a-mixer.md`](../../security/not-a-mixer.md) — canonical Blockaid-submission threat model.
- [`SECURITY.md`](../../../SECURITY.md) — disclosure + bug bounty + role disclosure.
- [`chainhackers/zk-guess-circuits` release `v2-ceremony`](https://github.com/chainhackers/zk-guess-circuits/releases/tag/v2-ceremony) — circuit, final zkey, ceremony transcript.
- Issue [#39](https://github.com/chainhackers/zk-guess-contracts/issues/39) — umbrella checkbox tracking.
- [`docs/superpowers/specs/2026-04-18-forfeit-rewards-merkle-distribution-design.md`](./2026-04-18-forfeit-rewards-merkle-distribution-design.md) — predecessor spec covering the v1 `Rewards` design that v2 inherited.
