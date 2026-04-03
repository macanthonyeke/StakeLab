// SPDX-License-Identifier: MIT
pragma solidity >0.8.18;

import "forge-std/Test.sol";

import "./StakeLab.t.sol";

contract YieldCoreSimulationTest is StakeLabTestBase {
    uint256 internal constant SIM_USER_COUNT = 1_000;
    uint256 internal constant SIM_ACTIONS = 50_000;
    uint256 internal constant USER_INITIAL_BALANCE = 250_000 * ONE;
    uint256 internal constant MAX_TRACKED_POSITIONS_PER_USER = 8;

    address[] internal simUsers;
    mapping(address => uint256[]) internal userPositions;

    uint256 internal totalFunded;
    uint256 internal totalRewardsPaid;

    function setUp() public override {
        super.setUp();

        totalFunded = INITIAL_REWARD_FUND;

        // Keep treasury well-capitalized for random reward-funding actions.
        token.mint(treasury, 500_000_000 * ONE);
        vm.prank(treasury);
        token.approve(address(core), type(uint256).max);

        for (uint256 i = 0; i < SIM_USER_COUNT; i++) {
            address user = vm.addr(uint256(keccak256(abi.encode("sim-user", i))));
            simUsers.push(user);

            token.mint(user, USER_INITIAL_BALANCE);
            vm.prank(user);
            token.approve(address(core), type(uint256).max);
        }
    }

    function test_LargeScaleEconomicSimulation() external {
        uint256 seed = uint256(keccak256("YieldCoreSimulationSeed"));
        uint256 actionsExecuted;

        for (uint256 i = 0; i < SIM_ACTIONS;) {
            actionsExecuted++;
            seed = _seedStep(seed, i);

            _runRandomizedAction(
                seed,
                8, // open
                12, // claim
                8, // close
                4, // fund
                68, // warp
                1 minutes,
                30 days
            );

            if (i % 1_000 == 0) {
                _assertEconomicInvariantsAt(i, "large-scale-sim");
            }

            unchecked {
                ++i;
            }
        }

        assertGe(actionsExecuted, 10_000);
        assertEq(actionsExecuted, SIM_ACTIONS);
        _assertEconomicInvariantsAt(SIM_ACTIONS, "large-scale-sim-final");
    }

    function test_Adversarial_RapidOpenCloseCycles_InvariantsHold() external {
        uint256 seed = uint256(keccak256("RapidOpenCloseCyclesSeed"));

        for (uint256 i = 0; i < 2_500;) {
            seed = _seedStep(seed, i);
            _rapidOpenCloseCycle(seed);

            if (i % 200 == 0) {
                _assertEconomicInvariantsAt(i, "rapid-open-close");
            }

            unchecked {
                ++i;
            }
        }

        _assertEconomicInvariantsAt(2_500, "rapid-open-close-final");
    }

    function test_Adversarial_EarlyWithdrawalPenaltyAbuse_InvariantsHold() external {
        uint256 seed = uint256(keccak256("EarlyPenaltyAbuseSeed"));

        for (uint256 i = 0; i < 3_000;) {
            seed = _seedStep(seed, i);

            address user = _randomActor(seed);
            uint256 balance = token.balanceOf(user);
            if (balance < ONE) continue;

            uint256 cap = 3_000 * ONE;
            uint256 maxAmount = balance < cap ? balance : cap;
            if (maxAmount < ONE) continue;

            uint256 amount = _randomAmount(seed >> 16, ONE, maxAmount);
            uint256 lockDuration = _randomLockDuration(seed >> 40);

            (bool opened, uint256 pid) = _tryOpen(user, amount, lockDuration);
            if (!opened) continue;

            // Always close before maturity to attempt penalty bypass.
            uint256 jump = _randomAmount(seed >> 72, 1, lockDuration - 1);
            _warpBy(jump);

            vm.prank(user);
            try core.closePosition(pid) returns (uint256 principalPaid, uint256 rewardPaid, uint256 penalty) {
                _recordReward(rewardPaid);
                assertGt(penalty, 0, "early withdrawal penalty bypassed");
                assertEq(principalPaid + penalty, amount, "principal split mismatch");
            } catch {}

            if (i % 200 == 0) {
                _assertEconomicInvariantsAt(i, "penalty-abuse");
            }

            unchecked {
                ++i;
            }
        }

        _assertEconomicInvariantsAt(3_000, "penalty-abuse-final");
    }

    function test_Adversarial_RewardClaimSpam_InvariantsHold() external {
        uint256 seed = uint256(keccak256("RewardClaimSpamSeed"));
        _primeUsersWithPositions(seed, 250);

        for (uint256 i = 0; i < 6_000;) {
            seed = _seedStep(seed, i);

            if (i % 3 == 0) {
                _actionWarpWithin(seed, 1 minutes, 2 hours);
            }

            // Claim-spam pattern: same block repeated attempts and mixed users.
            _actionClaim(seed);
            _actionClaim(seed >> 9);

            if (i % 17 == 0) {
                _actionOpen(seed >> 3);
            }

            if (i % 250 == 0) {
                _assertEconomicInvariantsAt(i, "claim-spam");
            }

            unchecked {
                ++i;
            }
        }

        _assertEconomicInvariantsAt(6_000, "claim-spam-final");
    }

    function test_Adversarial_EmissionExhaustion_InvariantsHold() external {
        uint256 seed = uint256(keccak256("EmissionExhaustionSeed"));

        // Ensure rewards are prefunded above emission cap for full exhaustion path.
        _fundRewardsAsTreasury(50_000_000 * ONE);
        _queueAndExecuteSetEmission(20 * ONE);

        _primeUsersWithPositions(seed, 200);

        // Large jump to exhaust max emission, then trigger update via open.
        _actionWarpWithin(seed, 120 days, 180 days);
        _actionOpen(seed >> 7);

        assertLe(core.totalEmitted(), core.maxEmission(), "emission cap breached");
        assertTrue(core.emissionFinished(), "emission should be marked finished");

        uint256 emittedBefore = core.totalEmitted();

        // Extreme jump after exhaustion should not emit more.
        _actionWarpWithin(seed >> 11, 3650 days, 3650 days);
        _actionOpen(seed >> 13);

        assertEq(core.totalEmitted(), emittedBefore, "emission advanced after exhaustion");
        _assertEconomicInvariantsAt(0, "emission-exhaustion-final");
    }

    function test_Adversarial_TreasuryUnderfunding_InvariantsHold() external {
        uint256 seed = uint256(keccak256("TreasuryUnderfundingSeed"));

        // Keep funding low, then accelerate emissions to create reward pressure.
        _queueAndExecuteSetEmission(5_000 * ONE);

        address userA = simUsers[0];
        address userB = simUsers[1];

        _tryOpen(userA, 400_000 * ONE, LOCK_30_DAYS);
        _tryOpen(userB, 400_000 * ONE, LOCK_30_DAYS);

        _actionWarpWithin(seed, 2 hours, 2 hours);

        if (userPositions[userA].length > 0) {
            _tryClaim(userA, userPositions[userA][0]);
        }
        if (userPositions[userB].length > 0) {
            uint256 pidB = userPositions[userB][0];
            _tryClaim(userB, pidB);
            _tryClose(userB, pidB);
        }

        for (uint256 i = 0; i < 4_000;) {
            seed = _seedStep(seed, i);
            _runRandomizedAction(
                seed,
                25, // open
                35, // claim
                25, // close
                0, // no extra funding in underfunding scenario
                15, // warp
                1 hours,
                14 days
            );

            if (i % 250 == 0) {
                _assertEconomicInvariantsAt(i, "treasury-underfunding");
            }

            unchecked {
                ++i;
            }
        }

        _assertEconomicInvariantsAt(4_000, "treasury-underfunding-final");
    }

    function test_Adversarial_ExtremeTimeJumps_InvariantsHold() external {
        uint256 seed = uint256(keccak256("ExtremeTimeJumpsSeed"));
        _primeUsersWithPositions(seed, 180);

        for (uint256 i = 0; i < 2_500;) {
            seed = _seedStep(seed, i);

            // Very large jumps to stress timestamp-dependent reward accounting.
            _actionWarpWithin(seed, 30 days, 10 * 365 days);

            _runRandomizedAction(
                seed >> 5,
                20, // open
                25, // claim
                20, // close
                10, // fund
                25, // warp
                1 days,
                365 days
            );

            if (i % 150 == 0) {
                _assertEconomicInvariantsAt(i, "extreme-time-jumps");
            }

            unchecked {
                ++i;
            }
        }

        _assertEconomicInvariantsAt(2_500, "extreme-time-jumps-final");
    }

    function _primeUsersWithPositions(uint256 seed, uint256 opens) internal {
        for (uint256 i = 0; i < opens;) {
            seed = _seedStep(seed, i);
            _actionOpen(seed);

            unchecked {
                ++i;
            }
        }
    }

    function _rapidOpenCloseCycle(uint256 seed) internal {
        address user = _randomActor(seed);
        uint256 balance = token.balanceOf(user);
        if (balance < ONE) return;

        uint256 cap = 5_000 * ONE;
        uint256 maxAmount = balance < cap ? balance : cap;
        if (maxAmount < ONE) return;

        uint256 amount = _randomAmount(seed >> 16, ONE, maxAmount);
        uint256 lockDuration = _randomLockDuration(seed >> 40);

        (bool opened, uint256 pid) = _tryOpen(user, amount, lockDuration);
        if (!opened) return;

        // Close quickly to maximize churn pressure.
        _actionWarpWithin(seed >> 64, 1 minutes, 12 hours);
        _tryClose(user, pid);
    }

    function _seedStep(uint256 seed, uint256 nonce) internal pure returns (uint256) {
        unchecked {
            uint256 x = seed + 0x9e3779b97f4a7c15 + nonce;
            x ^= (x << 13);
            x ^= (x >> 7);
            x ^= (x << 17);
            if (x == 0) return 1;
            return x;
        }
    }

    function _runRandomizedAction(
        uint256 seed,
        uint256 openWeight,
        uint256 claimWeight,
        uint256 closeWeight,
        uint256 fundWeight,
        uint256 warpWeight,
        uint256 minWarp,
        uint256 maxWarp
    ) internal {
        uint256 totalWeight = openWeight + claimWeight + closeWeight + fundWeight + warpWeight;
        if (totalWeight == 0) return;

        uint256 pick = seed % totalWeight;
        if (pick < openWeight) {
            _actionOpen(seed);
            return;
        }

        pick -= openWeight;
        if (pick < claimWeight) {
            _actionClaim(seed);
            return;
        }

        pick -= claimWeight;
        if (pick < closeWeight) {
            _actionClose(seed);
            return;
        }

        pick -= closeWeight;
        if (pick < fundWeight) {
            _actionFund(seed);
            return;
        }

        _actionWarpWithin(seed, minWarp, maxWarp);
    }

    function _randomActor(uint256 seed) internal view returns (address) {
        return simUsers[seed % simUsers.length];
    }

    function _tryOpen(address user, uint256 amount, uint256 lockDuration) internal returns (bool opened, uint256 pid) {
        if (userPositions[user].length >= MAX_TRACKED_POSITIONS_PER_USER) return (false, 0);

        vm.prank(user);
        try core.openPosition(amount, lockDuration) returns (uint256 newPid) {
            userPositions[user].push(newPid);
            return (true, newPid);
        } catch {}
    }

    function _tryClaim(address user, uint256 pid) internal {
        vm.prank(user);
        try core.claim(pid) returns (uint256 reward) {
            _recordReward(reward);
        } catch {}
    }

    function _tryClose(address user, uint256 pid) internal {
        vm.prank(user);
        try core.closePosition(pid) returns (uint256, uint256 rewardPaid, uint256) {
            _recordReward(rewardPaid);
        } catch {}
    }

    function _actionOpen(uint256 seed) internal {
        address user = _randomActor(seed);
        if (userPositions[user].length >= MAX_TRACKED_POSITIONS_PER_USER) return;

        uint256 balance = token.balanceOf(user);
        if (balance < ONE) return;

        uint256 cap = 10_000 * ONE;
        uint256 maxAmount = balance < cap ? balance : cap;
        if (maxAmount < ONE) return;

        uint256 amount = _randomAmount(seed >> 16, ONE, maxAmount);
        uint256 lockDuration = _randomLockDuration(seed >> 64);

        _tryOpen(user, amount, lockDuration);
    }

    function _actionClaim(uint256 seed) internal {
        address user = _randomActor(seed);
        uint256[] storage positions = userPositions[user];
        if (positions.length == 0) return;

        uint256 pid = positions[(seed >> 16) % positions.length];
        _tryClaim(user, pid);
    }

    function _actionClose(uint256 seed) internal {
        address user = _randomActor(seed);
        uint256[] storage positions = userPositions[user];
        if (positions.length == 0) return;

        uint256 idx = (seed >> 16) % positions.length;
        uint256 pid = positions[idx];

        vm.prank(user);
        try core.closePosition(pid) returns (uint256, uint256 rewardPaid, uint256) {
            _recordReward(rewardPaid);
            _removePositionAt(user, idx);
        } catch {}
    }

    function _actionFund(uint256 seed) internal {
        uint256 treasuryBal = token.balanceOf(treasury);
        if (treasuryBal < ONE) return;

        uint256 cap = 200_000 * ONE;
        uint256 maxAmount = treasuryBal < cap ? treasuryBal : cap;
        if (maxAmount < ONE) return;

        uint256 amount = _randomAmount(seed >> 24, ONE, maxAmount);

        vm.prank(treasury);
        try core.fundRewards(amount) {
            _recordFunding(amount);
        } catch {}
    }

    function _actionWarpWithin(uint256 seed, uint256 minJump, uint256 maxJump) internal {
        uint256 jump = _randomAmount(seed >> 32, minJump, maxJump);
        _warpBy(jump);
    }

    function _warpBy(uint256 jump) internal {
        vm.warp(block.timestamp + jump);
        vm.roll(block.number + 1);
    }

    function _fundRewardsAsTreasury(uint256 amount) internal {
        vm.prank(treasury);
        core.fundRewards(amount);
        _recordFunding(amount);
    }

    function _recordFunding(uint256 amount) internal {
        totalFunded += amount;
    }

    function _recordReward(uint256 amount) internal {
        totalRewardsPaid += amount;
    }

    function _removePositionAt(address user, uint256 idx) internal {
        uint256[] storage positions = userPositions[user];
        if (positions.length == 0 || idx >= positions.length) return;

        uint256 last = positions.length - 1;
        if (idx != last) {
            positions[idx] = positions[last];
        }
        positions.pop();
    }

    function _randomLockDuration(uint256 seed) internal pure returns (uint256) {
        uint256 pick = seed % 3;
        if (pick == 0) return LOCK_7_DAYS;
        if (pick == 1) return LOCK_30_DAYS;
        return LOCK_90_DAYS;
    }

    function _randomAmount(uint256 seed, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max <= min) return min;
        uint256 span = max - min + 1;
        return min + (seed % span);
    }

    function _assertEconomicInvariantsAt(uint256 step, string memory phase) internal {
        uint256 contractBalance = token.balanceOf(address(core));
        uint256 liabilities =
            core.totalPrincipalLiability() + core.rewardTreasuryLiability() + core.protocolFeeLiability();
        uint256 emitted = core.totalEmitted();
        uint256 emissionCap = core.maxEmission();

        bool insolvent = contractBalance < liabilities;
        bool capBreach = emitted > emissionCap;
        bool rewardsOverfunded = totalRewardsPaid > totalFunded;

        if (insolvent || capBreach || rewardsOverfunded) {
            emit log_string("STATE_INCONSISTENCY_DETECTED");
            emit log_named_string("phase", phase);
            emit log_named_uint("step", step);
            emit log_named_uint("contractBalance", contractBalance);
            emit log_named_uint("liabilities", liabilities);
            emit log_named_uint("totalPrincipalLiability", core.totalPrincipalLiability());
            emit log_named_uint("rewardTreasuryLiability", core.rewardTreasuryLiability());
            emit log_named_uint("protocolFeeLiability", core.protocolFeeLiability());
            emit log_named_uint("totalEmitted", emitted);
            emit log_named_uint("maxEmission", emissionCap);
            emit log_named_uint("totalRewardsPaid", totalRewardsPaid);
            emit log_named_uint("totalFunded", totalFunded);
        }

        assertGe(contractBalance, liabilities, "insolvent accounting");
        assertLe(emitted, emissionCap, "emission cap breached");
        assertLe(totalRewardsPaid, totalFunded, "rewards exceed funding");
    }

    function _assertEconomicInvariants() internal {
        _assertEconomicInvariantsAt(type(uint256).max, "generic");
    }
}
