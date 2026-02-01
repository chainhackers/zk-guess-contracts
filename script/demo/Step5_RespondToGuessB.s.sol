// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../../src/GuessGame.sol";

contract Step5_RespondToGuessB is Script {
    // Valid proof for correct guess (42)
    uint256[2] proofA = [
        uint256(20733104445222474913460899055922638733390515415268774731643134142498872084191),
        uint256(14000468808382636465462761302394038173719213862863751644422554851223456811411)
    ];
    uint256[2][2] proofB = [
        [
            uint256(14529324359401080920218683234881556919213052277135946418796017114639319774385),
            uint256(12129083737057255635218975576710777788141717515839459178762095078342656790038)
        ],
        [
            uint256(4006130398494418696741732007622629431845312574338850368957129174821663088541),
            uint256(5320382245369139568202711526684359871618209808068963385672210545364024687600)
        ]
    ];
    uint256[2] proofC = [
        uint256(11555678601106434654959630063997038302724273931564919993607610338934924583422),
        uint256(12395595758571672800576038452878068084738676055843400774526791354550122500902)
    ];
    uint256[4] pubSignals = [
        uint256(13354932457729771147254927911602504548850183657014898888488396374653942452945),
        1, // isCorrect = true
        42, // guess
        100 // maxNumber
    ];

    function run(address gameAddress, uint256 puzzleId, uint256 challengeId) external {
        GuessGame game = GuessGame(gameAddress);

        vm.startBroadcast();

        // Get puzzle and challenge info
        IGuessGame.Puzzle memory puzzle = game.getPuzzle(puzzleId);
        IGuessGame.Challenge memory challenge = game.getChallenge(puzzleId, challengeId);

        // Calculate expected prize
        uint256 expectedPrize = puzzle.bounty + challenge.stake;

        // Get winner's balance before
        uint256 winnerBalanceBefore = challenge.guesser.balance;

        game.respondToChallenge(puzzleId, challengeId, proofA, proofB, proofC, pubSignals);

        // Get winner's balance after
        uint256 winnerBalanceAfter = challenge.guesser.balance;
        uint256 actualPrize = winnerBalanceAfter - winnerBalanceBefore;

        console.log("=== RESPONDED TO GUESS B ===");
        console.log("Puzzle ID:", puzzleId);
        console.log("Challenge ID:", challengeId);
        console.log("Result: CORRECT! WINNER!");
        console.log("Winner:", challenge.guesser);
        console.log("Prize won:", actualPrize);
        console.log("  - From bounty:", puzzle.bounty);
        console.log("  - From stake:", challenge.stake);
        console.log("  - Total prize:", expectedPrize);
        console.log("");
        console.log("Creator collateral returned to internal balance");
        console.log("GAME OVER - Puzzle solved!");

        vm.stopBroadcast();
    }
}
