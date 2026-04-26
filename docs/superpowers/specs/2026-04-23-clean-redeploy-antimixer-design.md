# Clean-Redeploy Anti-Mixer Design

**Date:** 2026-04-23
**Status:** Draft → ready for implementation, partially shipped (Phase A in progress via circuits #9 + contracts PR #41)
**Related:** umbrella issue #39 (this repo), umbrella roadmap #10 (`chainhackers/zk-guess-circuits`)

## Context

The current Base mainnet deployment of zk-guess (`GuessGame` proxy `0xa05ebcf0f9aab5194c8a3ec8571a1d85d0a7f590`, `Rewards` `0x3f403b992a4b0a2a8820e8818cac17e6f7cd8c1c`, `GuessVerifier` `0xface0e73719e78e3bb020001fd10b62af9b3b6b8`) has drawn auditor / scanner concern because its bytecode-level shape overlaps with Tornado-class mixers: Groth16 verifier, payable deposits from many addresses, payouts "appearing" after a proof, ETH-only flows. Clustering heuristics (Blockaid's, likely others) cannot read the circuit and cannot distinguish "I know preimage of commitment to a number" from "I know preimage of a Merkle leaf."

A file-by-file review of the current contract confirms the protocol is **already structurally non-mixer**: payout recipients are never user-supplied; deposit→payout linkage is preserved in events; no set-membership proofs; variable denominations; N-to-1 economics; forfeits are permissionless with a 1-day public time guard. The problem is two-fold:

1. **On-chain signals are insufficiently legible** — events lack identifiers a clustering heuristic can use to confirm linkage; some funds flow through a bare `treasury.call{value: ...}("")` that looks indistinguishable from any other ETH wire; `Rewards` has an unlabeled `receive()` that accepts any ETH.
2. **The deployer/owner/funding graph is monolithic** — one EOA `0x4c7AE65565a8DF70cbAB1b8a504c56E39da59B7A` is deployer, owner, and funding source, and the same address has played the game (created puzzles, submitted guesses). The contract is taintable on day zero via creation graph alone, and Blockaid's heuristic can't separate "operator playing their own game" from "operator using their own contract to anonymize funds."

**Goal**: redeploy the entire stack from a new deployer, with hardening code changes, split wallet roles, a materially different circuit + verifier, and submit to Blockaid + Basescan before any flag accumulates against the new addresses. Treat existing deployment as v1; one-shot migrate (it has 3 puzzles, 0 challenges lifetime — effectively free).

## Goals

- **Replace every signal a clustering heuristic could match against the v1 deployment**: new code, new bytecode (verifier + game), new addresses, new wallet roles. Anything that survives is intentional and documented.
- **Make non-mixer structure machine-legible**: every inbound ETH labeled, every payout linked to its triggering challenge in events, every "discretionary" path replaced with a deterministic state machine.
- **Document the threat model** so the Blockaid `verifiedProject` submission lands with a clear, falsifiable explainer of why this isn't a mixer.
- **Preserve game logic semantics** — players' funds, the forfeit deadline, the prize math, the proof shape, all unchanged from a player's perspective. Migration is one-shot, no in-flight state to preserve.

## Non-goals

- **Safe multisig on owner.** The operator wallet stays an EOA for v2; multisig is Phase G follow-up. Adding it now stretches the timeline and the current owner surface (`pause`, `publishRoot`, `settleNext`) doesn't justify multisig friction.
- **Upgrading the v1 deployment in place.** v2 stays UUPS-upgradeable, but we are NOT reusing the v1 proxy. Clean redeploy means a brand-new proxy + impl + verifier; settling the v1 proxy and pointing the frontend at the new addresses is the cutover (see §"Why a redeploy and not an upgrade" below).
- **External audit of the rewrite.** Tracked as Phase G; landing one is a strong legitimacy marker but not a blocker for v2.
- **Designing the off-chain rewards rules engine.** Done in `chainhackers/zk-guess-rewards` and `scripts/rewards/compute-epoch.ts`; orthogonal to this redeploy.
- **Changing the proof system.** Still Groth16 over BN254; only the circuit's public inputs and one constant change.

## Why a redeploy and not an upgrade

UUPS would let us upgrade in place, but:

1. The v1 deployer/owner/funding monolith taints the contract via creation graph regardless of upgrades. New bytecode through the same proxy doesn't move that graph.
2. The verifier address is referenced inside `GuessGame` storage. A new circuit needs a new verifier, which needs to be reachable via that address. Re-pointing storage is doable but the v1 `GuessVerifier` bytecode would still be on-chain and forever in the v1 deployment graph.
3. v1 has 3 puzzles, 0 challenges, 0 ETH locked — migration cost is one `settleAll` call.
4. The Blockaid clustering hit is against the deployment graph, not the current implementation. A fresh deployer breaks the cluster.

## Coverage audit

Every piece of advice from the brainstorming session, with how it's addressed in this design:

| # | Advice | Status | Where addressed |
|---|---|---|---|
| 1 | Mixer-shape concern is the dominant signal | Acknowledged as core motivation | This doc |
| 2 | New deployer (day-zero taint via creation graph) | Adopted | Phase B |
| 3 | Operator never plays | Adopted (operational rule + disclosed) | Phase B + SECURITY.md |
| 4 | Operator doesn't trigger forfeits | Already true — `forfeitPuzzle` is permissionless, 1-day guard | Verified; preserved |
| 5 | Player-pulled forfeits with public time guard | Already true — `claimFromForfeited` is `msg.sender`-only | Verified; preserved |
| 6 | Sweep-to-treasury after longer timeout | Adopted — new `sweepStaleBounty(puzzleId)` after `RESPONSE_TIMEOUT + 90d` | Phase C |
| 7 | Bytecode mixer topology unavoidable with Groth16 + ETH | Acknowledged — compensated by structural differentiators | This doc |
| 8 | Recipient never user-supplied | Already true (only `msg.sender` or state-derived) | Verified |
| 9 | No admin function that redirects payouts / no claim-on-behalf | Already true | Verified |
| 10 | Deposit→payout linked in events | Adopted — `PuzzleSolved` gets indexed `challengeId`. (`ForfeitClaimed` already includes `amount` today at `IGuessGame.sol:96`.) | Phase C4 |
| 11 | Variable denominations — never add a standard pool | Adopted as standing rule | SECURITY.md |
| 12 | N-to-1 economics | Already true (many losing stakes → one winner) | Preserved |
| 13 | Verify both contracts on Basescan with full source + `@notice` | Adopted | Phase C (NatSpec) + Phase D |
| 14 | Publish circuit source + verifying key + link from NatSpec | Adopted — circuits Release + `@custom:circuit-repo` tag | Phase A + Phase C |
| 15 | Basescan public label via nametag | Adopted | Phase D |
| 16 | Blockaid `verifiedProject` submission with explainer | Adopted | Phase D + `docs/security/not-a-mixer.md` |
| 17 | Pre-disclose forfeit mechanism to Blockaid | Adopted | Phase D submission body |
| 18 | Separate funding wallet from deployer from operator; none plays | Adopted | Phase B |
| 19 | Fresh trusted-setup ceremony alone gives different verifier bytecode | Acknowledged — but ship semantic changes too | Phase A |
| 20 | Bind proof to `puzzleId` (replay protection) | Adopted | Phase A (circuits) — shipped in `circuits#9` |
| 21 | Explicit range checks on `guess` | Adopted | Phase A — shipped in `circuits#9` |
| 22 | Domain-separate commitment hash | Adopted | Phase A — shipped in `circuits#9` |
| 23 | Optional: bind `guesser` address into proof | Adopted (shipped despite being marked optional) | Phase A — shipped in `circuits#9` |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Off-chain (cold storage)                      │
│   ┌──────────────┐  ┌─────────────┐  ┌──────────────────────┐   │
│   │ deployer-v2  │  │   funding   │  │      operator        │   │
│   │ (one-shot,   │  │ (CEX-       │  │  (proxy owner,       │   │
│   │  retired)    │  │  withdraw   │  │   pause, publishRoot,│   │
│   │              │  │  only)      │  │   settleNext)        │   │
│   └──────┬───────┘  └──────┬──────┘  └──────────┬───────────┘   │
│          │ deploy           │ fund               │ admin         │
│          ▼                  ▼                    ▼               │
│  ┌────────────────────────────────────────────────────────┐     │
│  │              Base mainnet (post-deploy)                 │     │
│  │                                                         │     │
│  │  ┌─────────────┐    treasury    ┌──────────────────┐   │     │
│  │  │  GuessGame  │─────────────▶ │     Rewards      │   │     │
│  │  │  (proxy)    │  forfeit slash │  fundRewards()   │   │     │
│  │  └──────┬──────┘                │  publishRoot()   │   │     │
│  │         │ verifyProof           │  claim(proof)    │   │     │
│  │         ▼                       └──────────────────┘   │     │
│  │  ┌─────────────┐                                        │     │
│  │  │  Verifier   │  ← regenerated from v2 ceremony zkey  │     │
│  │  │  (Groth16)  │                                        │     │
│  │  └─────────────┘                                        │     │
│  └────────────────────────────────────────────────────────┘     │
│                           │                                      │
│                           │ events                               │
│                           ▼                                      │
│              ┌─────────────────────────┐                         │
│              │  HyperIndex GraphQL      │                        │
│              │  (Puzzle, Challenge,     │                        │
│              │   RewardEpoch, ...)      │                        │
│              └─────────────────────────┘                         │
└─────────────────────────────────────────────────────────────────┘
```

**Address graph after deploy:**
- Deployer: a fresh keypair, gets exactly enough ETH from `funding` to deploy, broadcasts ≤2 txs (one for each contract + initialize), transfers ownership to `operator`, then is retired forever. Public attestation: "this address only ever deploys."
- Funding: gets ETH from a named CEX (Coinbase/Kraken) withdrawal, never plays, never deploys, only sends ETH to the deployer (gas) and to `Rewards.fundRewards()` (pool top-ups, when needed).
- Operator: gets gas from funding; calls `pause`, `publishRoot`, `settleNext`/`settleAll`; never plays.
- The historical address `0x4c7AE6...9B7A` (current monolithic) is documented in `SECURITY.md` as a playtest account from the v1 era; not a v2 role.

## Phase A — Circuit v2 (`chainhackers/zk-guess-circuits`)

**Status: implemented; pending merge.** Circuits PR #9 is merged. Contracts PR #41 wires the new `[6]` public-signal shape into `respondToChallenge` and is open at the time of writing — `main` still carries the v1 `[4]` flow until that PR lands.

Four circuit changes, each on top of v1 (`Poseidon([number, salt])` commitment, public signals `[commitment, isCorrect, guess, maxNumber]`):

1. **Bind `puzzleId` as a public input.** Public signals become `[commitment, isCorrect, guess, maxNumber, puzzleId, ...]`. Forced into the constraint system via `puzzleIdSquared <== puzzleId * puzzleId`. Prevents a valid proof being replayable against any other puzzle that happens to share the same commitment.
2. **Bind `guesser` as a public input** (originally optional, shipped because cheap). Same idiom on a uint160 field element. Prevents a third party from front-running someone else's proof submission with their own `msg.sender`.
3. **Range-check `guess`** in-circuit (`1 <= guess <= maxNumber`) using two 16-bit comparators, mirroring the existing constraints on `number`. Game-well-formedness moves from UI-trusted to proof-layer-guaranteed.
4. **Domain-separate the commitment**: `Poseidon([DOMAIN_TAG, number, salt])` where `DOMAIN_TAG = keccak256("zkguess.v2") mod p(BN254) = 6000605569458108169701754207643449997818461959397281845176039583157698733685` (hard-coded constant). v1 commitments cannot collide with v2 under any future composition.

Final v2 public signals: `[commitment, isCorrect, guess, maxNumber, puzzleId, guesser]` (6 entries).

**Trusted-setup v2:** Fresh phase-2 ceremony with ≥3 independent contributors + a drand/Bitcoin block beacon. Tracked in `chainhackers/zk-guess-circuits/tasks/trusted-setup-v2.md`. Until the ceremony lands, contracts repo carries dev-build artifacts (`guess_dev.zkey`, `BUILD_INFO.txt` clearly marked `BUILD=dev`) for testing/preview only. The deployed mainnet `GuessVerifier.sol` is regenerated from the post-ceremony `guess_final.zkey`.

**Artifact release:** GitHub Release at `chainhackers/zk-guess-circuits/releases/tag/v2.0.0` with `circuit.r1cs`, `circuit.wasm`, `verification_key.json`, `guess_final.zkey`, and `MANIFEST.sha256`. Reproducibility is the legitimacy marker.

## Phase B — Wallet topology (three-role separation)

Generate three fresh keypairs. None ever creates a puzzle, submits a guess, or claims a reward. All three documented in `SECURITY.md`.

| Role | Purpose | Provenance requirement |
|---|---|---|
| **Deployer** (`deployer-v2`) | One-shot: deploys `GuessVerifier` + `Rewards` + `GuessGame` impl + `ERC1967Proxy`, calls `initialize`, `transferOwnership(operator)`. Retired immediately. | Funded only with exact-gas amount (≤0.01 ETH) from the funding wallet. No other history before or after. |
| **Funding** (`funding`) | Seeds `Rewards` via `fundRewards(purpose)`, tops up boost.xyz campaigns, pays operator gas. | Funded directly from a named CEX withdrawal (Coinbase / Kraken). No DEX swaps, no mixer-adjacent path in the actor graph. |
| **Operator** (`operator`) | Owner of both contracts post-deploy. Calls `pause()`, `publishRoot()`, `settleNext()`, `settleAll()`. | Funded by funding wallet with modest gas. No history of puzzle creation or guessing. |

**Operational rule:** the operator never plays the game. If the operator wants to play, use a separate wallet — disclosed in `SECURITY.md` and unlinked from operator funding.

## Phase C — Contract code changes (this repo)

All on a new feature branch from main. New proxy + new impl + new `Rewards` + new `GuessVerifier`; no upgrade of the v1 UUPS proxy.

### C0. v2 circuit wiring — **shipped via PR #41**

`respondToChallenge` takes `uint256[6]` public signals and validates `_pubSignals[4] == puzzleId` (`InvalidPuzzleIdBinding()`) and `_pubSignals[5] == uint256(uint160(challenge.guesser))` (`InvalidGuesserBinding()`). All cheap pubSignals equality checks now run before the expensive `verifyProof` pairing call (saves ~200k gas on malformed/replayed submissions).

### C1. `Rewards.sol`: gate funding

- Remove the bare `receive() external payable`.
- Add `fundRewards(string calldata purpose) external payable` that emits `RewardsFunded(address indexed funder, uint256 amount, string purpose)`.

Every inbound ETH to `Rewards` now carries a labeled purpose. Scanners see structured intent, not bare wires.

### C2. `GuessGame.sol`: route forfeit collateral through the labeled path

- `forfeitPuzzle` currently does `treasury.call{value: puzzle.collateral}("")`. Change to `Rewards(treasury).fundRewards{value: puzzle.collateral}("forfeit-collateral-routing")`.

The forfeit slash now emits `RewardsFunded(GuessGame, amount, "forfeit-collateral-routing")` on the Rewards side — every wire from the game to the rewards pool is labeled.

### C3. `GuessGame.sol`: add `sweepStaleBounty(uint256 puzzleId)`

- Permissionless. Requires `puzzle.forfeited == true` AND `block.timestamp >= puzzle.lastResponseTime + RESPONSE_TIMEOUT + CLAIM_TIMEOUT` where `CLAIM_TIMEOUT = 90 days`.
- Computes unclaimed bounty using the existing `challengesClaimed` cumulative divisor.
- Transfers unclaimed via `Rewards(treasury).fundRewards{value: unclaimed}("stale-bounty-sweep")`.
- Emits `StaleBountySwept(puzzleId, amount)`.

Turns the "funds sit indefinitely after forfeit if no one claims" surface into a deterministic state machine with a public time guard. No discretion; not redirectable to operator.

### C4. `GuessGame.sol`: enrich traceability events

- `PuzzleSolved(puzzleId, winner, prize)` → add indexed `challengeId`: `PuzzleSolved(uint256 indexed puzzleId, uint256 indexed challengeId, address winner, uint256 prize)`.
- `ForfeitClaimed` already includes `amount` (`event ForfeitClaimed(uint256 indexed puzzleId, address guesser, uint256 amount)` at `IGuessGame.sol:96`); no change needed.

Zero storage cost. Indexer handler updates accordingly.

### C5. `GuessGame.sol` + `Settleable.sol`: queue-based settlement

Replace the current `settle(address[])` (caller-supplied recipient list) with a deterministic queue, so settlement can never single-out or omit specific addresses.

- Add `EnumerableSet.AddressSet private _potentiallyOwed` (new storage slot; reduce `__gap[50]` → `__gap[49]`).
- Auto-register `msg.sender` into `_potentiallyOwed` on entry to `createPuzzle`, `submitGuess`, `claimFromForfeited`, `claimStakeFromSolved`, `withdraw`. One SSTORE per user on first interaction; SLOAD-only thereafter.
- Add `uint256 private _settleCursor`.
- New view `canSettle() external view returns (bool)`: paused AND every puzzle is terminal (`solved || cancelled || forfeited`) AND every forfeited puzzle has passed `RESPONSE_TIMEOUT + CLAIM_TIMEOUT`.
- New function `settleNext(uint256 n, string calldata reason) external onlyOwner`:
  - Requires `canSettle()`.
  - Advances `_settleCursor` by up to `n`, paying each address whose `_computeOwed(addr) > 0`.
  - Emits one `SettledBatch(cursorStart, cursorEnd, reason)` plus per-address `SettledPaid(addr, amount)`.
- Modify `settleAll(string calldata reason)` (no addresses):
  - Requires `canSettle() && _settleCursor >= _potentiallyOwed.length()`.
  - Sweeps any dust to treasury via `Rewards(treasury).fundRewards{value: dust}("final-settlement-dust")`.
  - Marks `settled = true`, renounces ownership.

Owner cannot single out arbitrary recipients; cannot omit recipients; cannot settle while a puzzle is live; cannot settle before the 90-day forfeit-claim window closes.

### C6. NatSpec coverage

- `@title`, `@notice`, `@dev` on both contracts at the contract level.
- `@notice` on every external function (e.g., "Creates a new puzzle with a hidden number; the creator deposits a bounty and collateral.").
- `@custom:security-contact security@chainhackers.xyz` on both.
- `@custom:circuit-repo https://github.com/chainhackers/zk-guess-circuits/releases/tag/v2.0.0` on `GuessGame`.
- `@custom:commitment-domain` on `GuessGame` referencing `DOMAIN_TAG`.
- `@custom:homepage https://zk-guess.chainhackers.xyz` on both.

Basescan readers see the WHY of every function in plain English without leaving the verified-source page.

### C7. Project-metadata deploy event

In `initialize` (or a new `initV2` call), emit one `ProjectMetadata(string homepage, string circuitRepo, string vkeyChecksum, string auditUrl)`. Audit URL can be empty initially. Indexers and scanners pick it up at deploy time without reading NatSpec.

## Phase D — Deploy, verify, submit

1. **Deploy script update** — `script/Deploy.s.sol` takes `owner` as a parameter (not `msg.sender`). The deployer broadcasts; immediately calls `transferOwnership(operator)` on both contracts in the same script when possible.
2. **CREATE2 salt (optional)** — current deploy flow is `script/Deploy.s.sol` (regular `CREATE`). If we add a deterministic-deployment script in Phase D (e.g., `script/DeployDeterministic.s.sol` — to be created), pick a salt distinct from v1 (`keccak256("zkguess.v2.2026-04")`). Not a hard requirement; vanity addresses are nice-to-have, not mixer-defense.
3. **Sourcify + Basescan verification** — `scripts/verify-sourcify.sh` and `scripts/verify-basescan.sh` for all four contracts (`GuessGame` impl, proxy, `Rewards`, `GuessVerifier`).
4. **Basescan nametag** — submit "ZK Guess Game" + `https://zk-guess.chainhackers.xyz` via the Basescan name-tag form for the proxy address.
5. **Blockaid `verifiedProject`** — submit at `https://report.blockaid.io/verifiedProject`. Body in `docs/security/not-a-mixer.md`. Required: proxy address, domain, chain (Base mainnet), Basescan-verified source link, circuit repo link, the four-point non-mixer explainer, pre-disclosure of the forfeit mechanism, reputation pointers (Farcaster mini-app listing, boost.xyz campaign, user count), and the threat-model URL.
6. **ENS** — register `zkguess.chainhackers.eth` (or similar), point to the proxy.

**Non-mixer explainer paragraph** (lives at `docs/security/not-a-mixer.md`, included verbatim in the Blockaid submission):

> zk-guess is a number-guessing game using Groth16 to prove equality of two plaintext values (committed secret = guessed number) while keeping the secret private. Unlike mixers: (1) every payout's recipient is fixed at deposit time — `prize → challenge.guesser`, never user-supplied at withdrawal; (2) deposit→payout linkage is preserved in every event (`puzzleId`, `challengeId`, `winner`); (3) stakes are continuous, not fixed denominations — there is no anonymity set; (4) economics are N-to-1 (many losing stakes fund one winner), the opposite of a mixer's 1-to-1 flow. The forfeit mechanism, which activates if a creator is silent for 24 hours, generates the unusual payout patterns a clustering heuristic may see; it's a deterministic state machine with a public time guard, not discretionary routing.

## Phase E — Documentation

1. **`SECURITY.md`** at repo root — disclosure contact, bug bounty terms (initial: acknowledgment + credit; monetary later), scope, role disclosure (which addresses play which roles, including the historical playtest account).
2. **`docs/security/not-a-mixer.md`** — canonical threat model & non-mixer explainer (the paragraph above plus the four points expanded).
3. **`docs/security/wallet-topology.md`** — the three-role design with provenance of each address.
4. **`script/rewards/RUNBOOK.md`** — already updated with `BASE_RPC_URL` and `EXPECTED_EPOCH`; will get v2 contract addresses post-deploy.
5. **Root `README.md`** — v2 addresses, link to `SECURITY.md` and the threat model.
6. **`docs/superpowers/specs/2026-04-23-clean-redeploy-antimixer-design.md`** — this document.

## Phase F — Migration (one-shot cutover)

Current v1 state: 3 puzzles lifetime, 0 challenges. Migration is effectively free.

1. Deploy v2 stack from new deployer (Phase D).
2. On v1 (`0xa05ebc…`): call existing `settleAll(address[], "migration-to-v2-antimixer")` with the creators of the 3 existing puzzles. v1 contract seals (`settled = true`).
3. Frontend (`zk-guess` repo) switches `VITE_GAME_ADDRESS` + `VITE_REWARDS_ADDRESS` + commitment-domain-tag to v2 values. Announce on Farcaster / boost.xyz.
4. Indexer (`zk-guess-indexer` repo) re-deployed pointing at v2 addresses; v1 indexer archived.
5. v1 `Rewards` (`0x3f40…`) — no migration needed; balance is currently 0. New v2 `Rewards` is the live one going forward.

## Phase G — Follow-ups (deferred, tracked, not blocking)

- **Safe multisig for owner.** Revisit once v2 is stable; current owner surface is small (`pause`, `publishRoot`, `settleNext`).
- **Named-firm audit.** Even a one-day public review is a strong legitimacy marker; pursue after Blockaid response.
- **GitHub Pages on `chainhackers/zk-guess-rewards`.** Currently blocked by private-repo + free plan. Decide: make repo public, upgrade plan, or move to a different host.
- **`computeCommitment` Poseidon-only FFI helper.** Test infrastructure speedup; ~21 minutes off integration runs. Out of scope of v2 deploy; cheap follow-up.
- **Frontend commitment-gen refactor** to use `DOMAIN_TAG` from a shared module. Lives in `chainhackers/zk-guess` repo.
- **Indexer handler updates** for the enriched event signatures (C4). Lives in `chainhackers/zk-guess-indexer`.

## Decisions (locked)

1. **Scope**: wallet topology + contract code hardening + legitimacy markers. Safe multisig for owner is **out** of v2 (revisit Phase G).
2. **Code changes**: gate `Rewards.receive()`, add `sweepStaleBounty`, enrich events, queue-based settlement. No other behavioural changes.
3. **Owed-set population**: auto-register on every interaction (one SSTORE per user, first-time only). Beats explicit registration.
4. **Migration**: one-shot cutover. v1 has 3 puzzles, 0 challenges — effectively free.
5. **Circuit changes**: puzzleId binding + guesser binding + guess range check + domain-separated commitment + fresh phase-2 ceremony + artifact release.
6. **GitHub issue granularity**: one umbrella issue (#39) with phases as checkboxes; one short list issue in circuits (#10). Per-task md files in circuits repo `tasks/`.

## Open items

- Drafting the final Blockaid non-mixer paragraph from the Phase D first draft. Currently the paragraph above is the working copy.
- Final wording of `SECURITY.md` bug bounty terms (acknowledgment + credit at minimum; monetary tier TBD).
- ENS subdomain choice — `zkguess.chainhackers.eth` vs. a separate full domain.

## Implementation status

| Phase | Status |
|---|---|
| A — Circuit v2 (puzzleId + guesser binding, range check, domain separation) | **Shipped** in `chainhackers/zk-guess-circuits#9`; consumer wiring in this repo's PR #41 |
| A — Trusted-setup ceremony | Tracked in `tasks/trusted-setup-v2.md`; not shipped |
| A — Artifact GitHub Release | Tracked in `tasks/publish-artifacts-release.md`; gated on ceremony |
| B — Wallet topology generation + funding | Not started |
| C0 — v2 circuit wiring + fail-fast pubSignals checks | **Shipped** via PR #41 |
| C1–C7 — Rewards funding gate, forfeit routing, sweep, events, settlement, NatSpec, deploy event | Not started |
| D — Deploy + verify + Blockaid + nametag + ENS | Not started; gated on Phase B + Phase C |
| E — Security docs | Not started; can ship in parallel with Phase C |
| F — Migration | Not started; gated on Phase D |
| G — Multisig, audit, Pages | Deferred |

## References

- Existing rewards spec: `docs/superpowers/specs/2026-04-18-forfeit-rewards-merkle-distribution-design.md`
- Umbrella issue (this repo): #39
- Circuits roadmap issue: `chainhackers/zk-guess-circuits#10`
- v1 deployment: `GuessGame` proxy `0xa05ebcf0f9aab5194c8a3ec8571a1d85d0a7f590`, `Rewards` `0x3f403b992a4b0a2a8820e8818cac17e6f7cd8c1c`, `GuessVerifier` `0xface0e73719e78e3bb020001fd10b62af9b3b6b8`
- v1 deployer/owner/funding (monolithic): `0x4c7AE65565a8DF70cbAB1b8a504c56E39da59B7A`
