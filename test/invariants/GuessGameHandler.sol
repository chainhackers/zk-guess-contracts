// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../../src/GuessGame.sol";
import "../../src/generated/GuessVerifier.sol";

/**
 * @title GuessGameHandler
 * @notice Handler contract for invariant testing that performs bounded actions on GuessGame
 * @dev Tracks ghost variables to help verify invariants
 */
contract GuessGameHandler is Test {
    GuessGame public immutable game;
    Groth16Verifier public immutable verifier;
    
    // Ghost variables for tracking state
    mapping(uint256 => uint256) public ghostTotalStakes; // Track total stakes per puzzle
    mapping(uint256 => bool) public ghostPuzzleExists;
    mapping(uint256 => bool) public ghostPuzzleSolved;
    mapping(uint256 => uint256) public ghostPuzzleFunds; // bounty + totalStaked per puzzle
    uint256 public ghostTotalContractFunds;
    
    // Actors
    address[] public creators;
    address[] public guessers;
    
    // Bounds for fuzzing
    uint256 constant MIN_STAKE = 0.001 ether;
    uint256 constant MAX_STAKE = 1 ether;
    uint256 constant MIN_BOUNTY = 0.001 ether;
    uint256 constant MAX_BOUNTY = 10 ether;
    uint8 constant MAX_GROWTH_PERCENT = 100;
    
    // Valid proofs for testing (from actual circuit)
    uint[2] validProofA_correct = [
        20733104445222474913460899055922638733390515415268774731643134142498872084191,
        14000468808382636465462761302394038173719213862863751644422554851223456811411
    ];
    uint[2][2] validProofB_correct = [
        [14529324359401080920218683234881556919213052277135946418796017114639319774385,
         12129083737057255635218975576710777788141717515839459178762095078342656790038],
        [4006130398494418696741732007622629431845312574338850368957129174821663088541,
         5320382245369139568202711526684359871618209808068963385672210545364024687600]
    ];
    uint[2] validProofC_correct = [
        11555678601106434654959630063997038302724273931564919993607610338934924583422,
        12395595758571672800576038452878068084738676055843400774526791354550122500902
    ];

    uint[2] validProofA_incorrect = [
        260224852269514550962255596791713148069192103530930225168509498623216740997,
        3464936673232863366747749560095954607406672448198506930195439109614243395305
    ];
    uint[2][2] validProofB_incorrect = [
        [18076787037990225159899307248733301104058781270403724423075272532649526747523,
         21163582130445499238873337568384386692136208661991064222861763232945956209076],
        [14700551543044113104786011479044690264965500866720142037325671448170897252180,
         248536395010580566114959855988956594661021088223112251086687402479116093507]
    ];
    uint[2] validProofC_incorrect = [
        3718774677296111965628987936986701738438916711731522663485615268638604855259,
        15664470303899517099778638779831003600948012776255763324223926677414563225933
    ];
    
    bytes32 constant COMMITMENT_42_123 = 0x1d869fb8246b6131377493aaaf1cc16a8284d4aedcb7277079df35d0d1d552d1;
    
    constructor(GuessGame _game, Groth16Verifier _verifier) {
        game = _game;
        verifier = _verifier;
        
        // Initialize actors
        for (uint i = 0; i < 3; i++) {
            creators.push(address(uint160(0x1000 + i)));
            guessers.push(address(uint160(0x2000 + i)));
        }
    }
    
    // Modifiers to bound inputs
    modifier boundBounty(uint256 bounty) {
        bounty = bound(bounty, MIN_BOUNTY, MAX_BOUNTY);
        _;
    }
    
    modifier boundStake(uint256 stake) {
        stake = bound(stake, MIN_STAKE, MAX_STAKE);
        _;
    }
    
    modifier boundGrowthPercent(uint8 percent) {
        percent = uint8(bound(uint256(percent), 0, MAX_GROWTH_PERCENT));
        _;
    }
    
    modifier useActor(address[] memory actors, uint256 actorSeed) {
        address actor = actors[actorSeed % actors.length];
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }
    
    // Bound helper - override StdUtils
    function bound(uint256 x, uint256 min, uint256 max) internal pure override returns (uint256) {
        if (x < min) return min;
        if (x > max) return max;
        return x;
    }
    
    // Handler functions
    function createPuzzle(
        uint256 bountyAmount,
        uint256 stakeRequired,
        uint8 growthPercent,
        uint256 creatorSeed
    ) 
        public 
        boundBounty(bountyAmount)
        boundStake(stakeRequired)
        boundGrowthPercent(growthPercent)
        useActor(creators, creatorSeed)
    {
        // Fund the creator
        vm.deal(creators[creatorSeed % creators.length], bountyAmount);
        
        try game.createPuzzle{value: bountyAmount}(
            COMMITMENT_42_123,
            stakeRequired,
            growthPercent
        ) returns (uint256 puzzleId) {
            // Update ghost variables
            ghostPuzzleExists[puzzleId] = true;
            ghostPuzzleFunds[puzzleId] = bountyAmount;
            ghostTotalContractFunds += bountyAmount;
        } catch {
            // Ignore reverts
        }
    }
    
    function submitGuess(
        uint256 puzzleId,
        uint256 guess,
        uint256 stakeAmount,
        uint256 guesserSeed
    )
        public
        boundStake(stakeAmount)
        useActor(guessers, guesserSeed)
    {
        if (!ghostPuzzleExists[puzzleId] || ghostPuzzleSolved[puzzleId]) return;
        
        // Fund the guesser
        vm.deal(guessers[guesserSeed % guessers.length], stakeAmount);
        
        try game.submitGuess{value: stakeAmount}(puzzleId, guess) returns (uint256) {
            // Update ghost variables
            ghostTotalStakes[puzzleId] += stakeAmount;
            ghostPuzzleFunds[puzzleId] += stakeAmount;
            ghostTotalContractFunds += stakeAmount;
        } catch {
            // Ignore reverts
        }
    }
    
    function respondToChallenge(
        uint256 challengeId,
        bool isCorrect,
        uint256 creatorSeed
    )
        public
        useActor(creators, creatorSeed)
    {
        // Get puzzle info
        try game.getChallenge(challengeId) returns (IGuessGame.Challenge memory challenge) {
            if (challenge.responded) return;
            
            uint256 puzzleId = game.challengeToPuzzle(challengeId);
            IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
            
            if (puzzle.solved) return;
            
            uint[3] memory pubSignals = [
                uint256(COMMITMENT_42_123),
                isCorrect ? 1 : 0,
                42
            ];
            
            uint256 balanceBefore = address(game).balance;
            
            try game.respondToChallenge(
                challengeId,
                isCorrect ? validProofA_correct : validProofA_incorrect,
                isCorrect ? validProofB_correct : validProofB_incorrect,
                isCorrect ? validProofC_correct : validProofC_incorrect,
                pubSignals
            ) {
                if (isCorrect) {
                    // Puzzle solved - funds distributed
                    ghostPuzzleSolved[puzzleId] = true;
                    uint256 distributed = puzzle.bounty + puzzle.totalStaked - puzzle.creatorReward;
                    ghostTotalContractFunds -= distributed;
                    ghostPuzzleFunds[puzzleId] = 0;
                }
                
                // Verify no ETH was created or destroyed
                uint256 balanceAfter = address(game).balance;
                assert(balanceBefore >= balanceAfter);
            } catch {
                // Ignore reverts
            }
        } catch {
            // Ignore if challenge doesn't exist
        }
    }
    
    function closePuzzle(uint256 puzzleId, uint256 creatorSeed)
        public
        useActor(creators, creatorSeed)
    {
        if (!ghostPuzzleExists[puzzleId] || ghostPuzzleSolved[puzzleId]) return;
        
        try game.getPuzzle(puzzleId) returns (IGuessGame.Puzzle memory puzzle) {
            if (puzzle.creator != creators[creatorSeed % creators.length]) return;
            
            uint256 expectedPayout = puzzle.bounty + puzzle.totalStaked;
            
            try game.closePuzzle(puzzleId) {
                // Update ghost variables
                ghostPuzzleFunds[puzzleId] = 0;
                ghostTotalContractFunds -= expectedPayout;
                ghostPuzzleExists[puzzleId] = false;
            } catch {
                // Ignore reverts
            }
        } catch {
            // Ignore
        }
    }
    
    // Helper to sum all active puzzle funds
    function sumActivePuzzleFunds() public view returns (uint256 total) {
        uint256 puzzleCount = game.puzzleCount();
        for (uint256 i = 0; i < puzzleCount; i++) {
            if (ghostPuzzleExists[i] && !ghostPuzzleSolved[i]) {
                IGuessGame.Puzzle memory puzzle = game.getPuzzle(i);
                total += puzzle.bounty + puzzle.totalStaked;
            }
        }
    }
}