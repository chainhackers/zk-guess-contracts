# Security Policy

## Reporting a vulnerability

**Email:** security@chainhackers.xyz

Please include:
- Affected contract(s) and address(es).
- A reproducing script or transaction (Foundry test preferred).
- Severity assessment (your view; we'll cross-check).
- Whether the issue is exploitable today on Base mainnet, exploitable only on a fork,
  or theoretical.

Do **not** open a public GitHub issue for live-funds vulnerabilities. We will acknowledge
within 72 hours and provide a disclosure timeline based on severity.

## Bug bounty

Initial tier (current):

- **Acknowledgment + credit** in the repo, the relevant PR, and the next release notes.
- A monetary tier is not yet active; will be added once the contract has accrued
  meaningful TVL. The published amount and ranges will live here when the tier opens.

Out-of-scope (these are known properties, not vulnerabilities):

- The `_potentiallyOwed` queue is auto-populated; users cannot unsubscribe. This is
  intentional — the owner cannot omit recipients from settlement.
- `ForfeitClaimed` recipients pay only their own gas; there is no relayer.
- `Rewards.claim` requires the caller to be the leaf address; no claim-on-behalf.
- The owner can `pause` the contract. Pausing blocks new puzzles and new guesses (the
  two `whenNotPaused`-gated entry points). It does **not** block `forfeitPuzzle`,
  `respondToChallenge`, or `cancelPuzzle` — these remain callable while paused so the
  permissionless time-guarded forfeit path and the creator's response window cannot be
  censored. It also does not block any user-initiated payout (`withdraw`,
  `claimFromForfeited`, `claimStakeFromSolved`, `Rewards.claim`).
- Forfeit can be triggered by anyone after `RESPONSE_TIMEOUT` (1 day). This is
  intentional — it is the time guard, not a discretionary action.

## Threat model

The canonical threat model and non-mixer explainer is at
[`docs/security/not-a-mixer.md`](docs/security/not-a-mixer.md). Submitted to Blockaid as
part of the `verifiedProject` filing.

## Wallet topology and admin authority

Three distinct keypairs control the v2 deployment, none of which ever plays the game.
Full disclosure (addresses, provenance, allowed actions) at
[`docs/security/wallet-topology.md`](docs/security/wallet-topology.md).

Briefly:

| Role | Authority | Constraint |
|---|---|---|
| Deployer | Deploy four contracts, call `initialize(owner=operator)`. May also deploy future `GuessGame` implementation contracts for UUPS upgrades; the operator (proxy owner) performs the actual `upgradeToAndCall`. | Never holds ownership. Never plays. |
| Funding | Sends ETH to deployer (exact gas) and operator (gas) and to `Rewards.fundRewards("donation")`. Itself funded by a single, disclosed CEX withdrawal (exchange name + tx hash recorded in [`docs/security/wallet-topology.md`](docs/security/wallet-topology.md)). | Never deploys. Never plays. Never holds ownership. |
| Operator | `owner()` of `GuessGame` proxy and `Rewards`. Calls `pause`, `publishRoot`, `settleNext`, `settleAll`. | Never plays. Never deploys. |

**Operational rule:** an operator wanting to play the game uses a separate disclosed
wallet, not linked to the operator funding graph.

## Historical (v1) disclosure

The v1 deployment used a single monolithic EOA
[`0x4c7AE65565a8DF70cbAB1b8a504c56E39da59B7A`](https://basescan.org/address/0x4c7AE65565a8DF70cbAB1b8a504c56E39da59B7A)
for deployer / owner / funder / playtest. That contributed to the Blockaid clustering
hit that motivated the v2 redeploy. The address has no admin authority on the v2 stack
and is documented in [`docs/security/wallet-topology.md`](docs/security/wallet-topology.md)
for transparency.

The v1 contracts are listed in the [README](README.md#deployed-contracts-base-mainnet)
and will be permanently sealed via `settleAll(...)` as part of the v2 cutover.

## Upgradeability

`GuessGame` uses the UUPS proxy pattern (`ERC1967Proxy` + `_authorizeUpgrade`-gated).
Upgrade authority lives with the operator role. There is no timelock today; this is
deliberate (small admin surface, paused state required for `settleAll`) but is on the
shortlist for Phase G alongside multisig migration.

`Rewards` is **not** upgradeable. To change reward distribution logic, deploy a new
`Rewards` and migrate.

## Out-of-scope contracts

- `src/generated/GuessVerifier.sol` is auto-generated from the circuits repo at
  [`chainhackers/zk-guess-circuits`](https://github.com/chainhackers/zk-guess-circuits).
  The deployed v2 verifier on Base mainnet
  ([`0xC6AACD8eAe397a92fA2175Dd0938e3A9c4f3582C`](https://basescan.org/address/0xC6AACD8eAe397a92fA2175Dd0938e3A9c4f3582C))
  corresponds to the `GuessVerifier.sol` artifact attached to release
  [`v2-ceremony`](https://github.com/chainhackers/zk-guess-circuits/releases/tag/v2-ceremony) —
  output of a phase-2 trusted-setup ceremony with 5 contributors plus a Bitcoin-block
  beacon (block 947059), sealed 2026-04-28. Bugs in this file should be reported against
  the circuits repo; we will rebuild, re-run the ceremony if soundness is affected, and
  redeploy.
- `lib/openzeppelin-contracts*` — please report OZ contract bugs upstream first; we
  will pin / patch as appropriate.
