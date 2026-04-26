// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./Rewards.sol";
import "./Settleable.sol";
import "./interfaces/IGroth16Verifier.sol";
import "./interfaces/IGuessGame.sol";

/// @title GuessGame
/// @notice ZK-based number guessing game with on-chain Groth16 proof verification
/// @dev Implements UUPS upgradeable pattern. Puzzle creators commit to a secret number,
///      guessers submit challenges with stakes, creators respond with ZK proofs.
/// @custom:repository https://github.com/chainhackers/zk-guess-contracts
/// @custom:circuit-repo https://github.com/chainhackers/zk-guess-circuits/releases/tag/v2.0.0
/// @custom:commitment-domain DOMAIN_TAG=6000605569458108169701754207643449997818461959397281845176039583157698733685 (= keccak256("zkguess.v2") mod p(BN254))
/// @custom:homepage https://zk-guess.chainhackers.xyz
/// @custom:security-contact security@chainhackers.xyz
contract GuessGame is IGuessGame, Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, Settleable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice External Groth16 verifier contract for ZK proof validation
    IGroth16Verifier public verifier;

    /// @notice Address receiving slashed collateral on puzzle forfeit
    address public treasury;

    /// @notice Total number of puzzles ever created (also serves as next puzzle ID)
    uint256 public puzzleCount;

    /// @notice Mapping from puzzle ID to puzzle data — read via `getPuzzle(puzzleId)`.
    /// @dev Internal because Solidity's auto-generated getter for a 16-field struct would
    ///      hit the EVM stack-too-deep limit when ABI-encoding the return tuple.
    mapping(uint256 => Puzzle) internal puzzles;

    /// @notice Mapping from puzzle ID and challenge ID to challenge data
    /// @dev Indexed as puzzleChallenges[puzzleId][challengeId]
    mapping(uint256 => mapping(uint256 => Challenge)) public puzzleChallenges;

    /// @notice Tracks whether a specific guess has been submitted for a puzzle
    /// @dev Prevents duplicate guesses: guessSubmitted[puzzleId][guess] = true
    mapping(uint256 => mapping(uint256 => bool)) public guessSubmitted;

    /// @notice Total stake amount per guesser per puzzle (for pending challenges only)
    /// @dev Indexed as guesserStakeTotal[puzzleId][guesser]. Decremented when creator responds,
    ///      used for forfeit/solved claim calculations.
    mapping(uint256 => mapping(address => uint256)) public guesserStakeTotal;

    /// @notice Number of pending challenges per guesser per puzzle
    /// @dev Decremented when challenge is responded to, used for forfeit claim distribution
    mapping(uint256 => mapping(address => uint256)) public guesserChallengeCount;

    /// @notice Whether a guesser has claimed their share from a forfeited/solved puzzle
    mapping(uint256 => mapping(address => bool)) public guesserClaimed;

    /// @notice Internal balances available for withdrawal via withdraw()
    /// @dev Credits accumulate from forfeit claims and solved puzzle stake claims
    mapping(address => uint256) public balances;

    /// @inheritdoc ISettleable
    bool public settled;

    /// @notice Whether an address has been paid during settlement (for settle() idempotency)
    mapping(address => bool) public settledPaid;

    /// @notice Minimum ETH required as bounty when creating a puzzle
    uint256 public constant MIN_BOUNTY = 0.0001 ether;

    /// @notice Minimum stake required per guess submission
    uint256 public constant MIN_STAKE = 0.00001 ether;

    /// @notice Time creator must wait after last challenge before cancelling puzzle
    uint256 public constant CANCEL_TIMEOUT = 1 days;

    /// @notice Time allowed for creator to respond before forfeit becomes possible
    uint256 public constant RESPONSE_TIMEOUT = 1 days;

    /// @notice Time after forfeit before unclaimed bounty becomes sweepable to the rewards pool
    /// @dev Generous window so guessers have plenty of time to claim. After this, `sweepStaleBounty`
    ///      converts the unclaimed remainder into a labeled `RewardsFunded` transfer instead of
    ///      letting it sit indefinitely (anti-mixer hardening: no discretionary indefinite holds).
    uint256 public constant CLAIM_TIMEOUT = 90 days;

    /// @dev Set of addresses that have ever interacted in a way that could leave funds owed
    ///      to them at settlement time. Auto-populated on first interaction with createPuzzle,
    ///      submitGuess, claimFromForfeited, claimStakeFromSolved, or withdraw. Forms the
    ///      deterministic queue iterated by settleNext — owner cannot single out or omit
    ///      individual recipients (anti-mixer hardening).
    EnumerableSet.AddressSet private _potentiallyOwed;

    /// @dev Cursor into _potentiallyOwed for settleNext. Advances monotonically.
    uint256 private _settleCursor;

    /// @dev Reserved storage gap for future upgrades (UUPS pattern)
    /// @dev Reduced from 50 to 47: _potentiallyOwed (2 slots: array + position mapping) and
    ///      _settleCursor (1 slot) consume 3 of the original gap slots.
    uint256[47] private __gap;

    /// @notice Disables initializers to prevent implementation contract from being initialized
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract with verifier, treasury, and owner addresses
    /// @param _verifier Address of the Groth16 verifier contract
    /// @param _treasury Address to receive slashed collateral on forfeit
    /// @param _owner Address with upgrade authority
    /// @dev Can only be called once via proxy. Sets up OwnableUpgradeable with _owner.
    ///      Emits ProjectMetadata so indexers and scanners can pick up the project pointers
    ///      at deploy time without parsing NatSpec.
    function initialize(address _verifier, address _treasury, address _owner) public initializer {
        if (_owner == address(0)) revert InvalidOwnerAddress();
        __Ownable_init(_owner);
        __Pausable_init();

        if (_verifier == address(0)) revert InvalidVerifierAddress();
        verifier = IGroth16Verifier(_verifier);

        // Reject EOAs and self-destructed contracts here so the funding-gate invariant is
        // enforced at deploy time — every wire from GuessGame into the rewards pool must
        // hit a contract with `fundRewards(string)`. Doesn't prove the target is actually
        // a Rewards instance, but eliminates the silent-EOA failure mode.
        if (_treasury == address(0) || _treasury.code.length == 0) revert InvalidTreasuryAddress();
        treasury = _treasury;

        emit ProjectMetadata(
            "https://zk-guess.chainhackers.xyz",
            "https://github.com/chainhackers/zk-guess-circuits/releases/tag/v2.0.0",
            "", // vkeyChecksum: filled in after the phase-2 ceremony produces guess_final.zkey
            "" // auditUrl: filled in after first published audit
        );
    }

    /// @notice Authorizes contract upgrades (UUPS pattern)
    /// @param newImplementation Address of new implementation (unused)
    /// @dev Only owner can authorize upgrades. Implementation intentionally empty.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Reverts if the contract has been permanently settled, or if msg.sender's funds
    ///      have already been distributed via settle()/settleAll() — prevents double payment.
    modifier notSettled() {
        if (settled || settledPaid[msg.sender]) revert ContractSettled();
        _;
    }

    /// @notice Permanently pause the contract — no new puzzles or guesses allowed
    /// @dev Only callable by owner. No unpause — this is a one-way seal.
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc IGuessGame
    function createPuzzle(bytes32 commitment, uint256 bounty, uint256 stakeRequired, uint256 maxNumber)
        external
        payable
        whenNotPaused
        notSettled
        returns (uint256 puzzleId)
    {
        if (bounty < MIN_BOUNTY) revert InsufficientBounty();
        if (msg.value < bounty) revert InsufficientDeposit();
        if (stakeRequired < MIN_STAKE) revert InsufficientStake();
        if (maxNumber == 0 || maxNumber > 65535) revert InvalidMaxNumber();

        uint256 collateral = msg.value - bounty;

        puzzleId = puzzleCount++;
        puzzles[puzzleId] = Puzzle({
            creator: msg.sender,
            solved: false,
            cancelled: false,
            forfeited: false,
            commitment: commitment,
            bounty: bounty,
            collateral: collateral,
            stakeRequired: stakeRequired,
            maxNumber: maxNumber,
            challengeCount: 0,
            pendingChallenges: 0,
            lastChallengeTimestamp: block.timestamp,
            lastResponseTime: 0,
            pendingAtForfeit: 0,
            challengesClaimed: 0,
            forfeitedAt: 0
        });

        _potentiallyOwed.add(msg.sender);

        emit PuzzleCreated(puzzleId, msg.sender, commitment, bounty, collateral, stakeRequired, maxNumber);
    }

    /// @inheritdoc IGuessGame
    function submitGuess(uint256 puzzleId, uint256 guess)
        external
        payable
        whenNotPaused
        notSettled
        returns (uint256 challengeId)
    {
        Puzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (puzzle.solved) revert PuzzleAlreadySolved();
        if (puzzle.cancelled) revert PuzzleCancelledError();
        if (puzzle.forfeited) revert PuzzleForfeitedError();
        if (msg.sender == puzzle.creator) revert CreatorCannotGuess();
        if (msg.value < puzzle.stakeRequired) revert InsufficientStake();
        if (guess == 0 || guess > puzzle.maxNumber) revert InvalidGuessRange();
        if (guessSubmitted[puzzleId][guess]) revert GuessAlreadySubmitted();

        guessSubmitted[puzzleId][guess] = true;

        challengeId = puzzle.challengeCount++;
        puzzle.pendingChallenges++;
        puzzle.lastChallengeTimestamp = block.timestamp;

        // Track per-guesser aggregates
        guesserStakeTotal[puzzleId][msg.sender] += msg.value;
        guesserChallengeCount[puzzleId][msg.sender]++;
        _potentiallyOwed.add(msg.sender);

        puzzleChallenges[puzzleId][challengeId] = Challenge({
            guesser: msg.sender, responded: false, guess: guess, stake: msg.value, timestamp: block.timestamp
        });

        emit ChallengeCreated(challengeId, puzzleId, msg.sender, guess, msg.value);
    }

    /// @inheritdoc IGuessGame
    function respondToChallenge(
        uint256 puzzleId,
        uint256 challengeId,
        uint256[2] calldata _pA,
        uint256[2][2] calldata _pB,
        uint256[2] calldata _pC,
        uint256[6] calldata _pubSignals
    ) external notSettled {
        Puzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (msg.sender != puzzle.creator) revert OnlyPuzzleCreator();
        if (puzzle.solved) revert PuzzleAlreadySolved();
        if (puzzle.cancelled) revert PuzzleCancelledError();
        if (puzzle.forfeited) revert PuzzleForfeitedError();

        Challenge storage challenge = puzzleChallenges[puzzleId][challengeId];
        if (challenge.guesser == address(0)) revert ChallengeNotFound();
        if (challenge.responded) revert ChallengeAlreadyResponded();

        bytes32 proofCommitment = bytes32(_pubSignals[0]);
        bool isCorrect = _pubSignals[1] == 1;
        uint256 proofGuess = _pubSignals[2];
        uint256 proofMaxNumber = _pubSignals[3];
        uint256 proofPuzzleId = _pubSignals[4];
        uint256 proofGuesser = _pubSignals[5];

        // Match cheap calldata equalities before the pairing check so malformed/replayed
        // submissions don't pay the ~200k gas verifyProof costs.
        if (proofCommitment != puzzle.commitment) revert InvalidProof();
        if (proofGuess != challenge.guess) revert InvalidProofForChallengeGuess();
        if (proofMaxNumber != puzzle.maxNumber) revert InvalidProof();
        if (proofPuzzleId != puzzleId) revert InvalidPuzzleIdBinding();
        if (proofGuesser != uint256(uint160(challenge.guesser))) revert InvalidGuesserBinding();

        if (!verifier.verifyProof(_pA, _pB, _pC, _pubSignals)) revert InvalidProof();

        challenge.responded = true;
        puzzle.pendingChallenges--;
        puzzle.lastResponseTime = block.timestamp;

        // Decrement guesser aggregates
        guesserStakeTotal[puzzleId][challenge.guesser] -= challenge.stake;
        guesserChallengeCount[puzzleId][challenge.guesser]--;

        emit ChallengeResponded(puzzleId, challengeId, isCorrect);

        if (isCorrect) {
            puzzle.solved = true;

            // Winner gets bounty + their stake back
            uint256 totalPrize = puzzle.bounty + challenge.stake;
            emit PuzzleSolved(puzzleId, challengeId, challenge.guesser, totalPrize);

            // Return collateral to creator
            balances[puzzle.creator] += puzzle.collateral;

            (bool success,) = challenge.guesser.call{value: totalPrize}("");
            if (!success) revert TransferFailed();
        } else {
            // Wrong guess: guesser gets stake back
            (bool success,) = challenge.guesser.call{value: challenge.stake}("");
            if (!success) revert TransferFailed();
        }
    }

    /// @inheritdoc IGuessGame
    function cancelPuzzle(uint256 puzzleId) external notSettled {
        Puzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (msg.sender != puzzle.creator) revert OnlyPuzzleCreator();
        if (puzzle.solved) revert PuzzleAlreadySolved();
        if (puzzle.cancelled) revert PuzzleCancelledError();
        if (puzzle.forfeited) revert PuzzleForfeitedError();
        if (puzzle.pendingChallenges > 0) revert HasPendingChallenges();
        if (block.timestamp < puzzle.lastChallengeTimestamp + CANCEL_TIMEOUT) revert CancelTooSoon();

        puzzle.cancelled = true;

        emit PuzzleCancelled(puzzleId);

        // Return bounty + collateral to creator
        (bool success,) = puzzle.creator.call{value: puzzle.bounty + puzzle.collateral}("");
        if (!success) revert TransferFailed();
    }

    /// @inheritdoc IGuessGame
    function forfeitPuzzle(uint256 puzzleId, uint256 timedOutChallengeId) external notSettled {
        Puzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (puzzle.solved) revert PuzzleAlreadySolved();
        if (puzzle.cancelled) revert PuzzleCancelledError();
        if (puzzle.forfeited) revert PuzzleForfeitedError();

        // Verify the provided challenge is pending (proves there are pending challenges)
        Challenge storage challenge = puzzleChallenges[puzzleId][timedOutChallengeId];
        if (challenge.guesser == address(0)) revert ChallengeNotFound();
        if (challenge.responded) revert ChallengeAlreadyResponded();

        // Check if creator is inactive (rolling deadline)
        // Reference time is when creator last showed activity
        // If never responded, use the provided challenge's timestamp as the starting point
        uint256 referenceTime = puzzle.lastResponseTime > 0 ? puzzle.lastResponseTime : challenge.timestamp;
        if (block.timestamp < referenceTime + RESPONSE_TIMEOUT) revert CreatorStillActive();

        // Mark puzzle as forfeited
        puzzle.forfeited = true;
        puzzle.pendingAtForfeit = puzzle.pendingChallenges;
        puzzle.forfeitedAt = block.timestamp;

        emit PuzzleForfeited(puzzleId, puzzle.pendingAtForfeit);

        // Route slashed collateral through the labeled funding path so every inbound transfer
        // to the rewards pool carries a scanner-readable purpose (anti-mixer hardening).
        // try/catch keeps the failure mode aligned with the rest of the contract: any treasury
        // misconfiguration surfaces as TransferFailed, not a foreign callee revert.
        if (puzzle.collateral > 0) {
            emit CollateralSlashed(puzzleId, puzzle.collateral);
            try Rewards(payable(treasury)).fundRewards{value: puzzle.collateral}("forfeit-collateral-routing") {
            // no-op
            }
            catch {
                revert TransferFailed();
            }
        }
    }

    /// @inheritdoc IGuessGame
    function claimFromForfeited(uint256 puzzleId) external notSettled {
        Puzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (!puzzle.forfeited) revert PuzzleNotForfeited();
        if (guesserClaimed[puzzleId][msg.sender]) revert AlreadyClaimed();

        uint256 myChallenges = guesserChallengeCount[puzzleId][msg.sender];
        uint256 myStake = guesserStakeTotal[puzzleId][msg.sender];
        if (myChallenges == 0) revert NothingToClaim();

        // Mark as claimed
        guesserClaimed[puzzleId][msg.sender] = true;

        // Cumulative difference, not (bounty * myChallenges) / pendingAtForfeit, because the
        // two integer divisions telescope to exactly bounty across all claims, with the last
        // claimant absorbing the remainder. Do not simplify to the single-division form.
        uint256 a = puzzle.challengesClaimed;
        uint256 b = a + myChallenges;
        puzzle.challengesClaimed = b;
        uint256 bountyShare =
            (puzzle.bounty * b) / puzzle.pendingAtForfeit - (puzzle.bounty * a) / puzzle.pendingAtForfeit;
        uint256 totalPayout = myStake + bountyShare;

        // Credit to internal balance
        balances[msg.sender] += totalPayout;
        _potentiallyOwed.add(msg.sender);

        emit ForfeitClaimed(puzzleId, msg.sender, totalPayout);
    }

    /// @inheritdoc IGuessGame
    function claimStakeFromSolved(uint256 puzzleId) external notSettled {
        Puzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (!puzzle.solved) revert PuzzleNotSolved();
        if (guesserClaimed[puzzleId][msg.sender]) revert AlreadyClaimed();

        uint256 myStake = guesserStakeTotal[puzzleId][msg.sender];
        if (myStake == 0) revert NothingToClaim();

        // Mark as claimed
        guesserClaimed[puzzleId][msg.sender] = true;

        // Credit stake to internal balance
        balances[msg.sender] += myStake;
        _potentiallyOwed.add(msg.sender);

        emit StakeClaimedFromSolved(puzzleId, msg.sender, myStake);
    }

    /// @inheritdoc IGuessGame
    function withdraw() external notSettled {
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        balances[msg.sender] = 0;
        _potentiallyOwed.add(msg.sender);

        emit Withdrawal(msg.sender, amount);

        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    /// @inheritdoc IGuessGame
    function sweepStaleBounty(uint256 puzzleId) external notSettled {
        Puzzle storage puzzle = puzzles[puzzleId];
        if (puzzle.creator == address(0)) revert PuzzleNotFound();
        if (!puzzle.forfeited) revert PuzzleNotForfeited();
        if (block.timestamp < puzzle.forfeitedAt + CLAIM_TIMEOUT) revert ClaimWindowOpen();

        // Telescoping cumulative division mirrors claimFromForfeited so the same totals
        // hold whether claims happen first or the sweep absorbs everything.
        uint256 a = puzzle.challengesClaimed;
        uint256 distributed = (puzzle.bounty * a) / puzzle.pendingAtForfeit;
        uint256 unclaimed = puzzle.bounty - distributed;
        if (unclaimed == 0) revert NothingToSweep();

        // Zero the bounty so any future claimFromForfeited returns only stake. Stakes are
        // tracked separately in guesserStakeTotal and remain claimable indefinitely; the
        // sweep takes the unclaimed bounty, nothing else.
        puzzle.bounty = 0;
        puzzle.challengesClaimed = puzzle.pendingAtForfeit;

        emit StaleBountySwept(puzzleId, unclaimed);

        try Rewards(payable(treasury)).fundRewards{value: unclaimed}("stale-bounty-sweep") {
        // no-op
        }
        catch {
            revert TransferFailed();
        }
    }

    /// @inheritdoc IGuessGame
    /// @dev O(puzzleCount) — owner pre-flights this off-chain or via static call before
    ///      paying the gas of `settleNext`. The cost is a single SLOAD per puzzle.
    function canSettle() public view returns (bool) {
        if (!paused()) return false;
        uint256 n = puzzleCount;
        for (uint256 i; i < n; i++) {
            Puzzle storage p = puzzles[i];
            if (!p.solved && !p.cancelled && !p.forfeited) return false;
            if (p.forfeited) {
                // forfeitedAt == 0 is treated as not-yet-elapsed (defensive against any path
                // that flips `forfeited = true` without setting the timestamp).
                if (p.forfeitedAt == 0 || block.timestamp < p.forfeitedAt + CLAIM_TIMEOUT) return false;
                // Forfeited bounty accounting must be frozen before settlement — otherwise
                // claimFromForfeited (still callable while paused) could shift _computeOwed
                // between settleNext batches and leak non-trivial bounty into settleAll's
                // dust sweep. Frozen means: every guesser claimed (challengesClaimed ==
                // pendingAtForfeit) or sweepStaleBounty was called (which sets the same).
                if (p.challengesClaimed != p.pendingAtForfeit) return false;
            }
        }
        return true;
    }

    /// @notice Number of addresses queued for settlement (auto-registered on first interaction)
    function potentiallyOwedCount() external view returns (uint256) {
        return _potentiallyOwed.length();
    }

    /// @notice Address at queue position `i` in the settlement queue
    /// @dev Useful for off-chain pre-flighting `settleNext` cursor planning
    function potentiallyOwedAt(uint256 i) external view returns (address) {
        return _potentiallyOwed.at(i);
    }

    /// @notice Current cursor position into the settlement queue (advanced by settleNext)
    function settleCursor() external view returns (uint256) {
        return _settleCursor;
    }

    /// @inheritdoc Settleable
    function _potentiallyOwedLength() internal view override returns (uint256) {
        return _potentiallyOwed.length();
    }

    /// @inheritdoc Settleable
    function _potentiallyOwedAt(uint256 i) internal view override returns (address) {
        return _potentiallyOwed.at(i);
    }

    /// @inheritdoc Settleable
    function _readSettleCursor() internal view override returns (uint256) {
        return _settleCursor;
    }

    /// @inheritdoc Settleable
    function _writeSettleCursor(uint256 v) internal override {
        _settleCursor = v;
    }

    /// @inheritdoc Settleable
    function _canSettle() internal view override returns (bool) {
        return canSettle();
    }

    /// @inheritdoc Settleable
    function _routeDustToTreasury(uint256 amount, string memory reason) internal override {
        // try/catch normalizes treasury misconfiguration to SettleTransferFailed, matching
        // the failure mode of the other outbound paths (forfeitPuzzle, sweepStaleBounty).
        try Rewards(payable(treasury)).fundRewards{value: amount}(reason) {
        // no-op
        }
        catch {
            revert SettleTransferFailed();
        }
    }

    function _isSettled() internal view override returns (bool) {
        return settled;
    }

    function _setSettled() internal override {
        settled = true;
    }

    function _isPaid(address addr) internal view override returns (bool) {
        return settledPaid[addr];
    }

    function _markPaid(address addr) internal override {
        settledPaid[addr] = true;
    }

    function _computeOwed(address addr) internal view override returns (uint256 owed) {
        owed = balances[addr];

        for (uint256 pid; pid < puzzleCount; pid++) {
            Puzzle storage p = puzzles[pid];

            // Unclaimed forfeit share
            if (p.forfeited && !guesserClaimed[pid][addr]) {
                uint256 myChallenges = guesserChallengeCount[pid][addr];
                if (myChallenges > 0) {
                    uint256 a = p.challengesClaimed;
                    uint256 bountyShare =
                        (p.bounty * (a + myChallenges)) / p.pendingAtForfeit - (p.bounty * a) / p.pendingAtForfeit;
                    owed += guesserStakeTotal[pid][addr] + bountyShare;
                }
            }

            // Unclaimed solved-puzzle stake (non-winners)
            if (p.solved && !guesserClaimed[pid][addr]) {
                uint256 myStake = guesserStakeTotal[pid][addr];
                if (myStake > 0) owed += myStake;
            }

            // Active puzzle creator funds
            if (!p.solved && !p.cancelled && !p.forfeited && p.creator == addr) {
                owed += p.bounty + p.collateral;
            }
        }
    }

    /// @inheritdoc IGuessGame
    function getPuzzle(uint256 puzzleId) external view returns (Puzzle memory) {
        return puzzles[puzzleId];
    }

    /// @inheritdoc IGuessGame
    function getChallenge(uint256 puzzleId, uint256 challengeId) external view returns (Challenge memory) {
        return puzzleChallenges[puzzleId][challengeId];
    }
}
