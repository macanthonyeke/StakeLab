// SPDX-License-Identifier: MIT
pragma solidity >0.8.18;

import "forge-std/Test.sol";

import "./StakeLab.t.sol";
import {IStakeLab} from "../src/Interface/IStakeLab.sol";

contract StakeLabFuzzTest is StakeLabTestBase {
    function testFuzz_DepositAmounts(uint256 actorSeed, uint256 rawAmount, uint256 lockSeed) external {
        address actor = _selectActor(actorSeed);
        vm.assume(actor != address(0));

        uint256 amount = bound(rawAmount, ONE, 100_000 * ONE);
        uint256 lockDuration = _selectLockDuration(lockSeed);

        uint256 pid = _openPositionAs(actor, amount, lockDuration);

        IStakeLab.Position memory p = core.getPosition(pid);
        assertEq(p.owner, actor);
        assertEq(p.amount, amount);
        assertEq(core.totalPrincipalLiability(), amount);
    }

    function testFuzz_LockDurations(uint256 actorSeed, uint256 rawAmount, uint256 lockSeed) external {
        address actor = _selectActor(actorSeed);
        uint256 amount = bound(rawAmount, ONE, 50_000 * ONE);

        uint256 lockDuration = _selectLockDuration(lockSeed);
        uint256 pid = _openPositionAs(actor, amount, lockDuration);

        IStakeLab.Position memory p = core.getPosition(pid);
        assertEq(p.lockDuration, lockDuration);
        assertGt(core.penaltyBpsByLockDuration(lockDuration), 0);
    }

    function testFuzz_RewardAccrual(uint256 rawAmount, uint256 rawWarp) external {
        uint256 amount = bound(rawAmount, ONE, 100_000 * ONE);
        uint256 warpSeconds = bound(rawWarp, 1 minutes, 30 days);

        uint256 pid = _openPositionAs(alice, amount, LOCK_30_DAYS);

        vm.warp(block.timestamp + warpSeconds);
        vm.roll(block.number + 1);

        uint256 preview = core.previewClaim(pid);
        uint256 emitted = warpSeconds * core.emissionPerSecond();
        uint256 accIncrement = (emitted * 1e18) / amount;
        uint256 expectedRoundedReward = (amount * accIncrement) / 1e18;

        assertEq(preview, expectedRoundedReward);

        vm.prank(alice);
        uint256 claimed = core.claim(pid);
        assertEq(claimed, expectedRoundedReward);
        assertEq(core.totalEmitted(), emitted);
    }

    function testFuzz_ClosePositions(uint256 actorSeed, uint256 rawAmount, uint256 lockSeed, uint256 rawJump) external {
        address actor = _selectActor(actorSeed);
        uint256 amount = bound(rawAmount, ONE, 100_000 * ONE);
        uint256 lockDuration = _selectLockDuration(lockSeed);

        uint256 pid = _openPositionAs(actor, amount, lockDuration);

        uint256 jump = bound(rawJump, 1 hours, lockDuration + 30 days);

        vm.warp(block.timestamp + jump);
        vm.roll(block.number + 1);

        uint256 expectedPenalty;
        if (jump < lockDuration) {
            expectedPenalty = (amount * core.penaltyBpsByLockDuration(lockDuration)) / BPS;
        }

        vm.prank(actor);
        (uint256 principalPaid,, uint256 penalty) = core.closePosition(pid);

        IStakeLab.Position memory p = core.getPosition(pid);
        assertFalse(p.active);
        assertEq(p.amount, 0);

        assertEq(penalty, expectedPenalty);
        assertEq(principalPaid + penalty, amount);
        assertEq(core.totalPrincipalLiability(), 0);
    }

    function testFuzz_PenaltyDistribution(uint256 rawAmountA, uint256 rawAmountB, uint256 rawJump, uint256 rawWithdraw)
        external
    {
        uint256 amountA = bound(rawAmountA, ONE, 100_000 * ONE);
        uint256 amountB = bound(rawAmountB, ONE, 100_000 * ONE);
        uint256 jump = bound(rawJump, 1 minutes, 3 days);

        uint256 pidA = _openPositionAs(alice, amountA, LOCK_90_DAYS);
        uint256 pidB = _openPositionAs(bob, amountB, LOCK_30_DAYS);

        vm.warp(block.timestamp + jump);
        vm.roll(block.number + 1);

        vm.prank(alice);
        (,, uint256 penaltyA) = core.closePosition(pidA);

        vm.prank(bob);
        (,, uint256 penaltyB) = core.closePosition(pidB);

        uint256 totalPenalty = penaltyA + penaltyB;
        assertEq(core.protocolFeeLiability(), totalPenalty);

        if (totalPenalty == 0) {
            return;
        }

        uint256 withdrawAmount = bound(rawWithdraw, 1, totalPenalty);
        _queueAndExecuteWithdrawProtocolFees(withdrawAmount);

        assertEq(core.protocolFeeLiability(), totalPenalty - withdrawAmount);
    }
}
