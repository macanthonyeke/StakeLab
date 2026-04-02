// SPDX-License-Identifier: MIT
pragma solidity >0.8.18;

import "forge-std/Test.sol";

import "./StakeLab.t.sol";

contract StakeLabAdversarialTest is StakeLabTestBase {
    function test_Adversarial_RewardDraining_ClaimSpamCannotOverdrawTreasury() external {
        uint256 attackerPid = _openPositionAs(attacker, 500_000 * ONE, LOCK_30_DAYS);
        uint256 alicePid = _openPositionAs(alice, 500_000 * ONE, LOCK_30_DAYS);

        uint256 funded = core.rewardTreasuryLiability();
        uint256 totalClaimed;

        for (uint256 i = 0; i < 40; i++) {
            _advance(3 hours);
            totalClaimed += _claimIfAny(attacker, attackerPid);
            totalClaimed += _claimIfAny(alice, alicePid);
        }

        assertLe(totalClaimed, funded);
        assertEq(core.rewardTreasuryLiability(), funded - totalClaimed);
        _assertSolvent();
    }

    function test_Adversarial_EarlyExitPenaltyBypass_UnconfiguredLock_Reverts() external {
        uint256 amount = 25_000 * ONE;
        uint256 unconfiguredLock = 365 days;

        assertEq(core.penaltyBpsByLockDuration(unconfiguredLock), 0);
        assertFalse(core.validLockDuration(unconfiguredLock));

        vm.prank(attacker);
        vm.expectRevert(StakeLab.InvalidLockDuration.selector);
        core.openPosition(amount, unconfiguredLock);
    }

    function test_Adversarial_EmissionOverflow_GriefsStateTransitions() external {
        uint256 pid = _openPositionAs(attacker, 1_000 * ONE, LOCK_30_DAYS);

        _queueAndExecuteSetEmission(type(uint256).max);
        _advance(2 seconds);

        vm.expectRevert(stdError.arithmeticError);
        core.previewClaim(pid);

        vm.prank(attacker);
        vm.expectRevert(stdError.arithmeticError);
        core.claim(pid);

        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        core.openPosition(1 * ONE, LOCK_7_DAYS);
    }

    function test_Adversarial_TreasuryUnderfunding_FirstClaimerCanStarveOthers() external {
        uint256 alicePid = _openPositionAs(alice, 400_000 * ONE, LOCK_30_DAYS);
        uint256 bobPid = _openPositionAs(bob, 400_000 * ONE, LOCK_30_DAYS);

        _queueAndExecuteSetEmission(5_000 * ONE);
        _advance(2 hours);

        uint256 funded = core.rewardTreasuryLiability();
        uint256 previewA = core.previewClaim(alicePid);
        uint256 previewB = core.previewClaim(bobPid);

        // Economic invariant break: aggregate pending rewards exceed funded rewards.
        assertGt(previewA + previewB, funded);

        vm.prank(alice);
        uint256 claimedA = core.claim(alicePid);
        assertEq(claimedA, previewA);

        assertGt(previewB, core.rewardTreasuryLiability());

        vm.prank(bob);
        vm.expectRevert(StakeLab.InsufficientRewardTreasury.selector);
        core.claim(bobPid);

        vm.prank(bob);
        vm.expectRevert(StakeLab.InsufficientRewardTreasury.selector);
        core.closePosition(bobPid);
    }

    function test_Adversarial_RapidOpenCloseCycles_UnconfiguredLockBlocked() external {
        uint256 amount = 10_000 * ONE;
        uint256 expectedPenalty = (amount * PENALTY_7D_BPS) / BPS;
        uint256 accruedPenalty;

        for (uint256 i = 0; i < 20; i++) {
            uint256 pid = _openPositionAs(attacker, amount, LOCK_7_DAYS);
            _advance(1 hours);

            vm.prank(attacker);
            (,, uint256 penalty) = core.closePosition(pid);

            assertEq(penalty, expectedPenalty);
            accruedPenalty += penalty;
        }

        assertEq(core.protocolFeeLiability(), accruedPenalty);

        uint256 unconfiguredLock = 365 days;
        assertFalse(core.validLockDuration(unconfiguredLock));

        for (uint256 i = 0; i < 20; i++) {
            vm.prank(attacker);
            vm.expectRevert(StakeLab.InvalidLockDuration.selector);
            core.openPosition(amount, unconfiguredLock);
        }

        // Fee liability remains unchanged because unconfigured lock opens are blocked.
        assertEq(core.protocolFeeLiability(), accruedPenalty);
        _assertSolvent();
    }

    function _claimIfAny(address actor, uint256 pid) internal returns (uint256 claimed) {
        uint256 pending = core.previewClaim(pid);
        if (pending == 0) return 0;

        vm.prank(actor);
        claimed = core.claim(pid);
    }

    function _advance(uint256 jump) internal {
        vm.warp(block.timestamp + jump);
        vm.roll(block.number + 1);
    }

    function _assertSolvent() internal view {
        uint256 liabilities =
            core.totalPrincipalLiability() + core.rewardTreasuryLiability() + core.protocolFeeLiability();
        assertGe(token.balanceOf(address(core)), liabilities);
    }
}
