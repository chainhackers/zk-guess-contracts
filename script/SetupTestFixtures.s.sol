// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/GuessGame.sol";

contract SetupTestFixtures is Script {
    GuessGame guessGame;
    
    // Test accounts (Anvil default accounts)
    address constant ACCOUNT_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant ACCOUNT_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant ACCOUNT_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant ACCOUNT_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant ACCOUNT_4 = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    
    function run() external {
        // Get contract address from environment or use default
        address contractAddr = vm.envOr("GUESS_GAME_ADDRESS", address(0));
        require(contractAddr != address(0), "GUESS_GAME_ADDRESS not set");
        
        guessGame = GuessGame(contractAddr);
        
        console.log("Setting up test fixtures for GuessGame at:", contractAddr);
        
        // Create diverse test puzzles
        createTestPuzzles();
        
        // Add some guesses to make it realistic
        addTestGuesses();
        
        // Show summary
        uint256 totalPuzzles = guessGame.puzzleCount();
        console.log("\n=== SETUP COMPLETE ===");
        console.log("Total puzzles created:", totalPuzzles);
        console.log("Contract address:", contractAddr);
        console.log("Ready for E2E testing!");
    }
    
    function createTestPuzzles() internal {
        console.log("\n--- Creating Test Puzzles ---");
        
        // Puzzle 1: Easy starter (secret=42)
        vm.startBroadcast(ACCOUNT_0);
        bytes32 commitment1 = keccak256(abi.encodePacked(uint256(42)));
        uint256 puzzle1 = guessGame.createPuzzle{value: 0.01 ether}(commitment1, 0.001 ether, 50);
        vm.stopBroadcast();
        console.log("Created Puzzle #%d: Easy starter (secret=42, bounty=0.01 ETH)", puzzle1);
        
        // Puzzle 2: High roller (secret=77)
        vm.startBroadcast(ACCOUNT_1);
        bytes32 commitment2 = keccak256(abi.encodePacked(uint256(77)));
        uint256 puzzle2 = guessGame.createPuzzle{value: 0.1 ether}(commitment2, 0.01 ether, 50);
        vm.stopBroadcast();
        console.log("Created Puzzle #%d: High roller (secret=77, bounty=0.1 ETH)", puzzle2);
        
        // Puzzle 3: Lucky number (secret=13)
        vm.startBroadcast(ACCOUNT_2);
        bytes32 commitment3 = keccak256(abi.encodePacked(uint256(13)));
        uint256 puzzle3 = guessGame.createPuzzle{value: 0.05 ether}(commitment3, 0.005 ether, 50);
        vm.stopBroadcast();
        console.log("Created Puzzle #%d: Lucky number (secret=13, bounty=0.05 ETH)", puzzle3);
        
        // Puzzle 4: Free play (secret=88, no stake)
        vm.startBroadcast(ACCOUNT_3);
        bytes32 commitment4 = keccak256(abi.encodePacked(uint256(88)));
        uint256 puzzle4 = guessGame.createPuzzle{value: 0.01 ether}(commitment4, 0, 0); // 0 stake = free
        vm.stopBroadcast();
        console.log("Created Puzzle #%d: Free play (secret=88, bounty=0.01 ETH, free)", puzzle4);
        
        // Puzzle 5: Big bounty (secret=99)
        vm.startBroadcast(ACCOUNT_4);
        bytes32 commitment5 = keccak256(abi.encodePacked(uint256(99)));
        uint256 puzzle5 = guessGame.createPuzzle{value: 0.2 ether}(commitment5, 0.02 ether, 50);
        vm.stopBroadcast();
        console.log("Created Puzzle #%d: Big bounty (secret=99, bounty=0.2 ETH)", puzzle5);
        
        // Puzzle 6: Quick game (secret=7)
        vm.startBroadcast(ACCOUNT_0);
        bytes32 commitment6 = keccak256(abi.encodePacked(uint256(7)));
        uint256 puzzle6 = guessGame.createPuzzle{value: 0.02 ether}(commitment6, 0.002 ether, 50);
        vm.stopBroadcast();
        console.log("Created Puzzle #%d: Quick game (secret=7, bounty=0.02 ETH)", puzzle6);
    }
    
    function addTestGuesses() internal {
        console.log("\n--- Adding Test Guesses ---");
        
        // Guesses on Puzzle 0 (Easy starter) - stake required: 0.001 ether
        vm.startBroadcast(ACCOUNT_1);
        guessGame.submitGuess{value: 0.001 ether}(0, 50);
        vm.stopBroadcast();
        console.log("Account 1 guessed 50 on Puzzle #0");
        
        vm.startBroadcast(ACCOUNT_2);
        guessGame.submitGuess{value: 0.001 ether}(0, 35);
        vm.stopBroadcast();
        console.log("Account 2 guessed 35 on Puzzle #0");
        
        vm.startBroadcast(ACCOUNT_3);
        guessGame.submitGuess{value: 0.001 ether}(0, 60);
        vm.stopBroadcast();
        console.log("Account 3 guessed 60 on Puzzle #0");
        
        // Guesses on Puzzle 1 (High roller) - stake required: 0.01 ether
        vm.startBroadcast(ACCOUNT_0);
        guessGame.submitGuess{value: 0.01 ether}(1, 80);
        vm.stopBroadcast();
        console.log("Account 0 guessed 80 on Puzzle #1");
        
        vm.startBroadcast(ACCOUNT_4);
        guessGame.submitGuess{value: 0.01 ether}(1, 70);
        vm.stopBroadcast();
        console.log("Account 4 guessed 70 on Puzzle #1");
        
        // Guess on Puzzle 2 (Lucky number) - stake required: 0.005 ether
        vm.startBroadcast(ACCOUNT_1);
        guessGame.submitGuess{value: 0.005 ether}(2, 10);
        vm.stopBroadcast();
        console.log("Account 1 guessed 10 on Puzzle #2");
        
        // Free guesses on Puzzle 3 (Free play) - stake required: 0
        vm.startBroadcast(ACCOUNT_2);
        guessGame.submitGuess{value: 0}(3, 90);
        vm.stopBroadcast();
        console.log("Account 2 guessed 90 on Puzzle #3 (free)");
        
        vm.startBroadcast(ACCOUNT_1);
        guessGame.submitGuess{value: 0}(3, 85);
        vm.stopBroadcast();
        console.log("Account 1 guessed 85 on Puzzle #3 (free)");
    }
}