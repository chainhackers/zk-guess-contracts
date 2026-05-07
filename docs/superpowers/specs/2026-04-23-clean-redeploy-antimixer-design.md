# Anti-Mixer Redeploy — As Built

**Status:** v2 launched 2026-05-05 (block 45605232); v2.1 redeployed
2026-05-07 (block 45686113) after the v2 launch verifier was found to have
been built from the dev-build zkey rather than the ceremony-final one.
v2.1 is the live stack.
**Issue:** [#39](https://github.com/chainhackers/zk-guess-contracts/issues/39) (umbrella tracker for the v2 redeploy).
**Related PRs:** #41 (C0 v2 circuit wiring) · #42 (this doc — original
pre-implementation draft, since superseded by the contents below) · #43
(Phase C contract hardening) · #44 (Phase B/D wallet topology + v2 launch
deploy) · #47 (this doc + v2.1 ceremony-verifier redeploy, closing #46).
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

v2.1 — live stack, deployed 2026-05-07 (block 45686113) after the dev-zkey
discovery on the v2 launch deploy. See `## v2.1 redeploy (2026-05-07)` below
for the discovery + resolution.

| Contract           | Address                                                                                                                       | Deploy tx                                                                                                                              |
|--------------------|-------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------|
| GuessGame proxy    | [`0x6F890B08fa4312135E1b4CF03929f8e389A866B4`](https://basescan.org/address/0x6F890B08fa4312135E1b4CF03929f8e389A866B4)        | [`0x6dab6120…`](https://basescan.org/tx/0x6dab612018783d7d9f950bfa5a61ea672a84c7badf94129861cfd17631a19bc4)                              |
| GuessGame impl     | [`0x9217A110A5663f8685f0251a5892662b9f0Efb19`](https://basescan.org/address/0x9217A110A5663f8685f0251a5892662b9f0Efb19)        | [`0x86180416…`](https://basescan.org/tx/0x86180416ba6a33d3fdeedb0774b1aa1470bc96bf2051890225817047a9bd8da9)                              |
| Verifier (Groth16) | [`0x2772322a14Ff01c8df663AD13aaC3dC15aF1EfA9`](https://basescan.org/address/0x2772322a14Ff01c8df663AD13aaC3dC15aF1EfA9)        | [`0xeb61182b…`](https://basescan.org/tx/0xeb61182ba7c4ac81a2eff3dae37e35e3948c88e50e7e1db0fb9923633738a93b)                              |
| Rewards            | [`0xE9f7aE2A1E574d47CfD19dfB6B2059a31e127f01`](https://basescan.org/address/0xE9f7aE2A1E574d47CfD19dfB6B2059a31e127f01)        | [`0xb0552206…`](https://basescan.org/tx/0xb055220602f6da5b55f488d8d2220e8e9f576dc4e513dfadbb4c1eee26ca5aa6)                              |

All four contracts verified on Sourcify and Basescan during the deploy run
(`forge script ... --verify --verifier sourcify` plus a post-deploy Basescan
verification pass).

### Superseded v2 launch addresses (deployed 2026-05-05, block 45605232; do not interact)

- GuessGame proxy: [`0xbA14152f40Df6673f316FD623313377Df6edD88A`](https://basescan.org/address/0xbA14152f40Df6673f316FD623313377Df6edD88A)
- GuessGame impl: [`0xe9813127Fc5927289966DDBe1B0c36bC5190E0F4`](https://basescan.org/address/0xe9813127Fc5927289966DDBe1B0c36bC5190E0F4)
- Verifier: [`0xC6AACD8eAe397a92fA2175Dd0938e3A9c4f3582C`](https://basescan.org/address/0xC6AACD8eAe397a92fA2175Dd0938e3A9c4f3582C) — built from the dev-build zkey, not the ceremony-final zkey
- Rewards: [`0x594A8b4fA394580f02c8C7B6450Fa5859F9b602F`](https://basescan.org/address/0x594A8b4fA394580f02c8C7B6450Fa5859F9b602F)

These contracts have zero state and zero ETH. They will remain on-chain
indefinitely (no deletion path) but are no longer referenced from this
repo.

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
originally-planned `v2.0.0`. The v2.1 redeploy (#46/#47) corrected the
on-chain `ProjectMetadata.circuitRepo` to point at the actual `v2-ceremony`
tag and populated `vkeyChecksum` with the SHA-256 of `verification_key.json`
(`2a0ae13d6d50943e65727831d614882463560b0c19ba789473b87b3c6ffc7179`). The
superseded v2 launch deploy still emits the stale `v2.0.0` URL but is no
longer referenced from this repo.

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

**C7 fields on the live v2.1 deploy:** `circuitRepo` points at the actual
[`v2-ceremony`](https://github.com/chainhackers/zk-guess-circuits/releases/tag/v2-ceremony)
release, `vkeyChecksum` is `2a0ae13d6d50943e65727831d614882463560b0c19ba789473b87b3c6ffc7179`
(SHA-256 of `verification_key.json` from the release), `auditUrl` is blank
pending the Phase G named-firm audit. The superseded v2 launch deploy
emitted `circuitRepo=v2.0.0` (non-existent tag) and blank checksums; that
mismatch was the proximate trigger for the v2.1 redeploy (#46/#47).

## Phase D — Deploy / verify / submit

v2.1 deployed 2026-05-07, block 45686113 (per-contract tx hashes in the
deployed-contracts table above). All four contracts verified on Sourcify
and Basescan during the deploy script. v2 launch (2026-05-05, block
45605232) is superseded.

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

## v2.1 redeploy (2026-05-07)

The v2 launch deploy (2026-05-05, block 45605232) shipped with the
**dev-build verifier** rather than the ceremony-final one. Discovery:
during Phase D Blockaid-filing prep, `diff src/generated/GuessVerifier.sol`
against the `GuessVerifier.sol` artifact in the
[`v2-ceremony`](https://github.com/chainhackers/zk-guess-circuits/releases/tag/v2-ceremony)
release showed different `delta{x1,x2,y1,y2}` constants — the proving key
came from the dev contributor's single-shot setup, not the public
5-contributor + BTC-block-947059 ceremony. The repository's own
`circuits/BUILD_INFO.txt` had said exactly this: `BUILD=dev / WARNING:
Single-contributor dev setup, NOT a trusted-setup ceremony. Do not deploy
the derived GuessVerifier.sol to mainnet.` The warning was followed at
import time but lost track of by the deploy.

Resolution path chosen: fresh redeploy (v2.1) rather than UUPS
reinitializer upgrade. v2 had zero usage state (`puzzleCount=0`, 0 ETH on
proxy and Rewards, `currentEpoch=0`), so the reinitializer's only benefit
(proxy address stability) was moot. Source PR #47 swapped the verifier
file + zkey + tooling references and corrected the `ProjectMetadata`
strings in `initialize`. Same `scripts/deploy-mainnet.sh` then redeployed
all four contracts on 2026-05-07 (block 45686113); same Phase B keypairs
(deployer/funding/operator) and same `.env`. All four v2.1 contracts
verified on Sourcify and Basescan during the deploy.

Audit-trail note: the superseded v2 launch contracts remain on-chain
indefinitely (no deletion path), with zero state, zero ETH, and no admin
calls. They are not referenced from this repo or its docs.

## Locked decisions (delta from the 2026-04-23 draft)

1. **Init-time owner**, not post-deploy `transferOwnership(operator)`.
   Deployer EOA never holds ownership at any point.
2. **Deployer keypair retained** for future impl redeploys (UUPS upgrades),
   not retired after the v2 launch tx batch.
3. **KuCoin** as funding-source CEX (regional access; Coinbase/Kraken don't
   operate in Russia). Disclosure principle preserved.
4. **Release tag `v2-ceremony`**, not `v2.0.0`. The v2.1 deploy emits the
   correct URL on-chain.
5. **No CREATE2 / `DeployDeterministic.s.sol`.** Vanity addresses are not a
   meaningful mixer-defense signal.
6. **`MAX_DUST` cap dropped** after PR #44 round-2 review (SELFDESTRUCT
   griefing of finalization). See Phase C5 above.
7. **Three-role separation enforced in code**
   (`vm.startBroadcast(deployer)` + `OWNER != DEPLOYER` require), not just
   operationally.
8. **v1 cutover deferred** to a separate PR (Phase F). v2 contracts are live
   independently of v1 sealing.
9. **Fresh redeploy over reinitializer upgrade** (v2.1, #46/#47) since v2
   had zero usage. Simpler audit trail, no UUPS reinit subtleties.

## References

- [`docs/security/wallet-topology.md`](../../security/wallet-topology.md) — full per-address provenance + audit subgraph queries.
- [`docs/security/not-a-mixer.md`](../../security/not-a-mixer.md) — canonical Blockaid-submission threat model.
- [`SECURITY.md`](../../../SECURITY.md) — disclosure + bug bounty + role disclosure.
- [`chainhackers/zk-guess-circuits` release `v2-ceremony`](https://github.com/chainhackers/zk-guess-circuits/releases/tag/v2-ceremony) — circuit, final zkey, ceremony transcript.
- Issue [#39](https://github.com/chainhackers/zk-guess-contracts/issues/39) — umbrella checkbox tracking.
- [`docs/superpowers/specs/2026-04-18-forfeit-rewards-merkle-distribution-design.md`](./2026-04-18-forfeit-rewards-merkle-distribution-design.md) — predecessor spec covering the v1 `Rewards` design that v2 inherited.
