// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../../src/GuessGame.sol";

contract Step3_RespondToGuessA is Script {
    // Valid proof for incorrect guess (50)
    uint256[2] proofA = [
        uint256(260224852269514550962255596791713148069192103530930225168509498623216740997),
        uint256(3464936673232863366747749560095954607406672448198506930195439109614243395305)
    ];
    uint256[2][2] proofB = [
        [
            uint256(18076787037990225159899307248733301104058781270403724423075272532649526747523),
            uint256(21163582130445499238873337568384386692136208661991064222861763232945956209076)
        ],
        [
            uint256(14700551543044113104786011479044690264965500866720142037325671448170897252180),
            uint256(248536395010580566114959855988956594661021088223112251086687402479116093507)
        ]
    ];
    uint256[2] proofC = [
        uint256(3718774677296111965628987936986701738438916711731522663485615268638604855259),
        uint256(15664470303899517099778638779831003600948012776255763324223926677414563225933)
    ];
    uint256[4] pubSignals = [
        uint256(13354932457729771147254927911602504548850183657014898888488396374653942452945),
        0, // isCorrect = false
        50, // guess
        100 // maxNumber
    ];

    function run(address gameAddress, uint256 puzzleId, uint256 challengeId) external {
        GuessGame game = GuessGame(gameAddress);

        vm.startBroadcast();

        // Get puzzle state before response
        IGuessGame.Puzzle memory puzzleBefore = game.getPuzzle(puzzleId);

        game.respondToChallenge(puzzleId, challengeId, proofA, proofB, proofC, pubSignals);

        // Get puzzle state after response
        IGuessGame.Puzzle memory puzzleAfter = game.getPuzzle(puzzleId);

        console.log("=== RESPONDED TO GUESS A ===");
        console.log("Puzzle ID:", puzzleId);
        console.log("Challenge ID:", challengeId);
        console.log("Result: INCORRECT");
        console.log("Pending challenges:", puzzleAfter.pendingChallenges);
        console.log("Bounty:", puzzleAfter.bounty);

        vm.stopBroadcast();
    }
}
