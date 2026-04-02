// SPDX-License-Identifier: MIT
pragma solidity >0.8.18;

import "forge-std/Test.sol";

import {StakeLab} from "../src/StakeLab.sol";
import {IStakeLab} from "../src/Interface/IStakeLab.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

abstract contract StakeLabTestBase is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ONE = 1e18;

    uint256 internal constant USER_MINT = 1_000_000 * ONE;
    uint256 internal constant TREASURY_MINT = 50_000_000 * ONE;

    uint256 internal constant INITIAL_REWARD_FUND = 5_000_000 * ONE;
    uint256 internal constant EMISSION_PER_SECOND = 1e15; // 0.001 token / second
    uint256 internal constant MAX_EMISSION = 30_000_000 * ONE;
    uint256 internal constant MIN_ACTION_DELAY = 1 days;

    uint256 internal constant LOCK_7_DAYS = 7 days;
    uint256 internal constant LOCK_30_DAYS = 30 days;
    uint256 internal constant LOCK_90_DAYS = 90 days;

    uint256 internal constant PENALTY_7D_BPS = 300;
    uint256 internal constant PENALTY_30D_BPS = 900;
    uint256 internal constant PENALTY_90D_BPS = 1500;

    address internal alice;
    address internal bob;
    address internal charlie;
    address internal attacker;
    address internal treasury;
    address internal guardian;

    address internal admin;
    address internal timelock;
    address internal protocolTreasury;

    MockERC20 internal token;
    StakeLab internal core;

    event PositionOpened(address indexed user, uint256 indexed positionId, uint256 amount, uint256 lockDuration);
    event RewardClaimed(address indexed user, uint256 indexed positionId, uint256 reward);
    event PositionClosed(
        address indexed user, uint256 indexed positionId, uint256 principalPaid, uint256 rewardPaid, uint256 penalty
    );
    event EmergencyWithdrawal(address indexed user, uint256 indexed positionId, uint256 amount);
    event RewardFunded(address indexed funder, uint256 amount);
    event SurplusCaptured(uint256 amount);
    event ProtocolFeesWithdrawn(address indexed protocolTreasury, uint256 amount);

    function setUp() public virtual {
        // Actors required by the test plan.
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        attacker = makeAddr("attacker");
        treasury = makeAddr("treasury");
        guardian = makeAddr("guardian");

        // Operational roles used by protocol controls.
        admin = makeAddr("admin");
        timelock = makeAddr("timelock");
        protocolTreasury = makeAddr("protocolTreasury");

        token = new MockERC20("Mock Stake", "MSTK");

        core = new StakeLab(
            token,
            admin,
            guardian,
            treasury,
            timelock,
            guardian,
            protocolTreasury,
            MIN_ACTION_DELAY,
            EMISSION_PER_SECOND,
            MAX_EMISSION
        );

        _mintAndApprove(alice, USER_MINT);
        _mintAndApprove(bob, USER_MINT);
        _mintAndApprove(charlie, USER_MINT);
        _mintAndApprove(attacker, USER_MINT);
        _mintAndApprove(treasury, TREASURY_MINT);

        // Seed reward treasury with realistic liquidity.
        vm.prank(treasury);
        core.fundRewards(INITIAL_REWARD_FUND);

        // Initialize lock-duration penalty schedule through timelock flow.
        _queueAndExecuteSetPenalty(LOCK_7_DAYS, PENALTY_7D_BPS);
        _queueAndExecuteSetPenalty(LOCK_30_DAYS, PENALTY_30D_BPS);
        _queueAndExecuteSetPenalty(LOCK_90_DAYS, PENALTY_90D_BPS);
    }

    function _mintAndApprove(address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(core), type(uint256).max);
    }

    function _queueAndWarp(bytes32 actionId) internal {
        vm.prank(timelock);
        core.queueAction(actionId);

        vm.warp(block.timestamp + core.MIN_ACTION_DELAY() + 1);
        vm.roll(block.number + 1);
    }

    function _queueAndExecuteSetPenalty(uint256 lockDuration, uint256 bps) internal {
        bytes32 actionId = keccak256(abi.encode(core.setPenaltyBps.selector, lockDuration, bps));
        _queueAndWarp(actionId);

        vm.prank(admin);
        core.setPenaltyBps(lockDuration, bps, actionId);
    }

    function _queueAndExecuteCaptureSurplus(uint256 amount) internal {
        bytes32 actionId = keccak256(abi.encode(core.captureSurplus.selector, amount));
        _queueAndWarp(actionId);

        vm.prank(treasury);
        core.captureSurplus(amount, actionId);
    }

    function _queueAndExecuteWithdrawProtocolFees(uint256 amount) internal {
        bytes32 actionId = keccak256(abi.encode(core.withdrawProtocolFees.selector, amount));
        _queueAndWarp(actionId);

        vm.prank(treasury);
        core.withdrawProtocolFees(amount, actionId);
    }

    function _queueAndExecuteSetEmission(uint256 newRate) internal {
        bytes32 actionId = keccak256(abi.encode(core.setEmissionPerSecond.selector, newRate));
        _queueAndWarp(actionId);

        vm.prank(admin);
        core.setEmissionPerSecond(newRate, actionId);
    }

    function _openPositionAs(address user, uint256 amount, uint256 lockDuration) internal returns (uint256) {
        vm.prank(user);
        return core.openPosition(amount, lockDuration);
    }

    function _selectActor(uint256 seed) internal view returns (address) {
        uint256 idx = seed % 4;
        if (idx == 0) return alice;
        if (idx == 1) return bob;
        if (idx == 2) return charlie;
        return attacker;
    }

    function _selectLockDuration(uint256 seed) internal pure returns (uint256) {
        uint256 idx = seed % 3;
        if (idx == 0) return LOCK_7_DAYS;
        if (idx == 1) return LOCK_30_DAYS;
        return LOCK_90_DAYS;
    }
}

contract StakeLabTest is StakeLabTestBase {
    function test_OpenPosition() external {
        uint256 amount = 1_250 * ONE;

        vm.expectEmit(true, true, true, true);
        emit PositionOpened(alice, 1, amount, LOCK_30_DAYS);

        uint256 positionId = _openPositionAs(alice, amount, LOCK_30_DAYS);
        assertEq(positionId, 1);

        IStakeLab.Position memory p = core.getPosition(positionId);
        assertEq(p.owner, alice);
        assertEq(p.amount, amount);
        assertEq(p.lockDuration, LOCK_30_DAYS);
        assertTrue(p.active);

        assertEq(core.totalPrincipalLiability(), amount);
    }

    function test_Revert_OpenPositionZeroAmount() external {
        vm.prank(alice);
        vm.expectRevert(StakeLab.InvalidAmount.selector);
        core.openPosition(0, LOCK_30_DAYS);
    }

    function test_Revert_InvalidLockDuration() external {
        vm.prank(alice);
        vm.expectRevert(StakeLab.InvalidLockDuration.selector);
        core.openPosition(100 * ONE, 0);
    }

    function test_OpenMultiplePositions() external {
        uint256 id1 = _openPositionAs(alice, 100 * ONE, LOCK_7_DAYS);
        uint256 id2 = _openPositionAs(alice, 200 * ONE, LOCK_30_DAYS);
        uint256 id3 = _openPositionAs(bob, 300 * ONE, LOCK_90_DAYS);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);

        assertEq(core.getUserPositionCount(alice), 2);
        assertEq(core.getUserPositionCount(bob), 1);

        uint256[] memory positions = core.getUserPositionsPaginated(alice, 0, 10);
        assertEq(positions.length, 2);
        assertEq(positions[0], 1);
        assertEq(positions[1], 2);
    }

    function test_PositionAccountingCorrect() external {
        uint256 aliceAmount = 1_000 * ONE;
        uint256 bobAmount = 2_500 * ONE;

        uint256 alicePid = _openPositionAs(alice, aliceAmount, LOCK_30_DAYS);
        uint256 bobPid = _openPositionAs(bob, bobAmount, LOCK_7_DAYS);

        assertEq(core.totalPrincipalLiability(), aliceAmount + bobAmount);

        IStakeLab.Position memory aliceP = core.getPosition(alicePid);
        IStakeLab.Position memory bobP = core.getPosition(bobPid);
        assertEq(aliceP.rewardDebt, 0);
        assertEq(bobP.rewardDebt, 0);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        uint256 charliePid = _openPositionAs(charlie, 500 * ONE, LOCK_7_DAYS);
        IStakeLab.Position memory charlieP = core.getPosition(charliePid);

        assertGt(charlieP.rewardDebt, 0);
        assertEq(core.totalPrincipalLiability(), aliceAmount + bobAmount + (500 * ONE));
    }

    function test_ClaimRewards() external {
        uint256 positionId = _openPositionAs(alice, 1_000 * ONE, LOCK_30_DAYS);

        vm.warp(block.timestamp + 2 days);
        vm.roll(block.number + 1);

        uint256 preview = core.previewClaim(positionId);
        assertGt(preview, 0);

        vm.expectEmit(true, true, true, true);
        emit RewardClaimed(alice, positionId, preview);

        uint256 beforeBal = token.balanceOf(alice);

        vm.prank(alice);
        uint256 reward = core.claim(positionId);

        assertEq(reward, preview);
        assertEq(token.balanceOf(alice) - beforeBal, reward);
        assertEq(core.rewardTreasuryLiability(), INITIAL_REWARD_FUND - reward);
    }

    function test_Revert_ClaimWithoutRewards() external {
        uint256 positionId = _openPositionAs(alice, 1_000 * ONE, LOCK_7_DAYS);

        vm.prank(alice);
        vm.expectRevert(StakeLab.NoRewards.selector);
        core.claim(positionId);
    }

    function test_RewardsAccrueOverTime() external {
        uint256 positionId = _openPositionAs(alice, 1_000 * ONE, LOCK_30_DAYS);

        vm.warp(block.timestamp + 10 minutes);
        uint256 rewardMinute = core.previewClaim(positionId);

        vm.warp(block.timestamp + 6 hours);
        uint256 rewardHour = core.previewClaim(positionId);

        vm.warp(block.timestamp + 7 days);
        uint256 rewardWeek = core.previewClaim(positionId);

        assertGt(rewardMinute, 0);
        assertGt(rewardHour, rewardMinute);
        assertGt(rewardWeek, rewardHour);
    }

    function test_RewardsMatchExpectedEmission() external {
        uint256 positionId = _openPositionAs(alice, 10_000 * ONE, LOCK_30_DAYS);

        uint256 elapsed = 3 days;
        vm.warp(block.timestamp + elapsed);
        vm.roll(block.number + 1);

        uint256 expected = elapsed * core.emissionPerSecond();

        vm.prank(alice);
        uint256 reward = core.claim(positionId);

        assertEq(reward, expected);
        assertEq(core.totalEmitted(), expected);
    }

    function test_ClosePositionAfterLock() external {
        uint256 amount = 1_000 * ONE;
        uint256 positionId = _openPositionAs(alice, amount, LOCK_7_DAYS);

        vm.warp(block.timestamp + LOCK_7_DAYS + 1);
        vm.roll(block.number + 1);

        uint256 preview = core.previewClaim(positionId);
        uint256 beforeBal = token.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit PositionClosed(alice, positionId, amount, preview, 0);

        vm.prank(alice);
        (uint256 principalPaid, uint256 rewardPaid, uint256 penalty) = core.closePosition(positionId);

        assertEq(principalPaid, amount);
        assertEq(rewardPaid, preview);
        assertEq(penalty, 0);
        assertEq(token.balanceOf(alice) - beforeBal, amount + rewardPaid);
        assertEq(core.totalPrincipalLiability(), 0);

        IStakeLab.Position memory p = core.getPosition(positionId);
        assertFalse(p.active);
        assertEq(p.amount, 0);
    }

    function test_ClosePositionEarlyPenalty() external {
        uint256 amount = 1_000 * ONE;
        uint256 positionId = _openPositionAs(alice, amount, LOCK_30_DAYS);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        uint256 expectedPenalty = (amount * PENALTY_30D_BPS) / BPS;

        vm.prank(alice);
        (uint256 principalPaid,, uint256 penalty) = core.closePosition(positionId);

        assertEq(principalPaid, amount - expectedPenalty);
        assertEq(penalty, expectedPenalty);
        assertEq(core.protocolFeeLiability(), expectedPenalty);
        assertEq(core.totalPrincipalLiability(), 0);
    }

    function test_PenaltyAccountingCorrect() external {
        uint256 p1 = _openPositionAs(alice, 2_000 * ONE, LOCK_90_DAYS);
        uint256 p2 = _openPositionAs(bob, 1_500 * ONE, LOCK_30_DAYS);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        vm.prank(alice);
        (,, uint256 penalty1) = core.closePosition(p1);

        vm.prank(bob);
        (,, uint256 penalty2) = core.closePosition(p2);

        uint256 totalPenalty = penalty1 + penalty2;
        assertEq(core.protocolFeeLiability(), totalPenalty);

        _queueAndExecuteWithdrawProtocolFees(totalPenalty / 2);
        assertEq(core.protocolFeeLiability(), totalPenalty - (totalPenalty / 2));
    }

    function test_EmergencyWithdraw() external {
        uint256 amount = 500 * ONE;
        uint256 positionId = _openPositionAs(alice, amount, LOCK_30_DAYS);

        vm.prank(guardian);
        core.pause();

        vm.expectEmit(true, true, true, true);
        emit EmergencyWithdrawal(alice, positionId, amount);

        vm.prank(alice);
        core.emergencyWithdraw(positionId);

        assertEq(core.totalPrincipalLiability(), 0);

        IStakeLab.Position memory p = core.getPosition(positionId);
        assertFalse(p.active);
        assertEq(p.amount, 0);
    }

    function test_Revert_EmergencyWithdrawWhenNotPaused() external {
        uint256 positionId = _openPositionAs(alice, 500 * ONE, LOCK_30_DAYS);

        vm.prank(alice);
        vm.expectRevert();
        core.emergencyWithdraw(positionId);
    }

    function test_Pause() external {
        vm.prank(guardian);
        core.pause();

        assertTrue(core.paused());

        vm.prank(alice);
        vm.expectRevert();
        core.openPosition(100 * ONE, LOCK_7_DAYS);
    }

    function test_Unpause() external {
        vm.prank(guardian);
        core.pause();

        vm.prank(guardian);
        core.unpause();

        assertFalse(core.paused());

        uint256 pid = _openPositionAs(alice, 100 * ONE, LOCK_7_DAYS);
        assertEq(pid, 1);
    }

    function test_FundRewards() external {
        uint256 amount = 1_000 * ONE;

        uint256 beforeLiability = core.rewardTreasuryLiability();
        uint256 beforeBalance = token.balanceOf(address(core));

        vm.expectEmit(true, true, true, true);
        emit RewardFunded(treasury, amount);

        vm.prank(treasury);
        core.fundRewards(amount);

        assertEq(core.rewardTreasuryLiability(), beforeLiability + amount);
        assertEq(token.balanceOf(address(core)), beforeBalance + amount);
    }

    function test_Revert_FundRewardsUnauthorized() external {
        vm.prank(alice);
        vm.expectRevert();
        core.fundRewards(10 * ONE);
    }

    function test_SurplusCapture() external {
        uint256 surplus = 250 * ONE;

        vm.prank(attacker);
        token.transfer(address(core), surplus);

        assertEq(core.getUnencumberedBalance(), surplus);

        uint256 beforeTreasury = token.balanceOf(protocolTreasury);

        _queueAndExecuteCaptureSurplus(surplus);

        assertEq(token.balanceOf(protocolTreasury), beforeTreasury + surplus);
        assertEq(core.getUnencumberedBalance(), 0);
    }

    function test_SurplusCannotBreakLiabilities() external {
        uint256 surplus = 100 * ONE;
        vm.prank(attacker);
        token.transfer(address(core), surplus);

        uint256 invalidAmount = surplus + 1;
        bytes32 actionId = keccak256(abi.encode(core.captureSurplus.selector, invalidAmount));
        _queueAndWarp(actionId);

        vm.prank(treasury);
        vm.expectRevert(StakeLab.InvalidAmount.selector);
        core.captureSurplus(invalidAmount, actionId);
    }

    function test_WithdrawProtocolFees() external {
        uint256 positionId = _openPositionAs(alice, 1_000 * ONE, LOCK_90_DAYS);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        vm.prank(alice);
        (,, uint256 penalty) = core.closePosition(positionId);

        assertGt(penalty, 0);

        uint256 withdrawAmount = penalty / 2;
        uint256 beforeTreasury = token.balanceOf(protocolTreasury);

        _queueAndExecuteWithdrawProtocolFees(withdrawAmount);

        assertEq(core.protocolFeeLiability(), penalty - withdrawAmount);
        assertEq(token.balanceOf(protocolTreasury), beforeTreasury + withdrawAmount);
    }

    function test_Revert_WithdrawMoreThanLiability() external {
        vm.prank(treasury);
        vm.expectRevert(StakeLab.InsufficientProtocolFeeAmount.selector);
        core.withdrawProtocolFees(1 * ONE, bytes32(0));
    }

    function test_GetUserPositionsPaginated() external {
        _openPositionAs(alice, 100 * ONE, LOCK_7_DAYS);
        _openPositionAs(alice, 200 * ONE, LOCK_30_DAYS);
        _openPositionAs(alice, 300 * ONE, LOCK_90_DAYS);
        _openPositionAs(alice, 400 * ONE, LOCK_7_DAYS);
        _openPositionAs(alice, 500 * ONE, LOCK_30_DAYS);

        uint256[] memory page1 = core.getUserPositionsPaginated(alice, 0, 2);
        uint256[] memory page2 = core.getUserPositionsPaginated(alice, 2, 2);
        uint256[] memory page3 = core.getUserPositionsPaginated(alice, 4, 2);

        assertEq(page1.length, 2);
        assertEq(page1[0], 1);
        assertEq(page1[1], 2);

        assertEq(page2.length, 2);
        assertEq(page2[0], 3);
        assertEq(page2[1], 4);

        assertEq(page3.length, 1);
        assertEq(page3[0], 5);
    }

    function test_PaginationBounds() external {
        _openPositionAs(alice, 100 * ONE, LOCK_7_DAYS);
        _openPositionAs(alice, 200 * ONE, LOCK_30_DAYS);

        uint256[] memory emptyFromLimit = core.getUserPositionsPaginated(alice, 0, 0);
        uint256[] memory emptyFromStart = core.getUserPositionsPaginated(alice, 20, 3);
        uint256[] memory clipped = core.getUserPositionsPaginated(alice, 1, 10);

        assertEq(emptyFromLimit.length, 0);
        assertEq(emptyFromStart.length, 0);

        assertEq(clipped.length, 1);
        assertEq(clipped[0], 2);
    }

    function test_Attack_RewardDrainingAttempt() external {
        uint256 alicePid = _openPositionAs(alice, 1_000 * ONE, LOCK_30_DAYS);

        vm.warp(block.timestamp + 2 days);
        vm.roll(block.number + 1);

        vm.prank(attacker);
        vm.expectRevert(StakeLab.NotPositionOwner.selector);
        core.claim(alicePid);
    }

    function test_Attack_EarlyWithdrawalPenaltyBypass() external {
        uint256 pid = _openPositionAs(attacker, 2_000 * ONE, LOCK_90_DAYS);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        vm.prank(attacker);
        (,, uint256 penalty) = core.closePosition(pid);

        assertGt(penalty, 0);
        assertEq(penalty, (2_000 * ONE * PENALTY_90D_BPS) / BPS);
    }

    function test_Attack_EmissionCapBypass() external {
        uint256 localMaxEmission = 100 * ONE;

        StakeLab capCore = new StakeLab(
            token,
            admin,
            guardian,
            treasury,
            timelock,
            guardian,
            protocolTreasury,
            MIN_ACTION_DELAY,
            1 * ONE,
            localMaxEmission
        );

        vm.prank(alice);
        token.approve(address(capCore), type(uint256).max);

        vm.prank(treasury);
        token.approve(address(capCore), type(uint256).max);

        vm.prank(treasury);
        capCore.fundRewards(1_000 * ONE);

        bytes32 actionId = keccak256(abi.encode(capCore.setPenaltyBps.selector, LOCK_30_DAYS, PENALTY_30D_BPS));
        vm.prank(timelock);
        capCore.queueAction(actionId);

        vm.warp(block.timestamp + capCore.MIN_ACTION_DELAY() + 1);
        vm.roll(block.number + 1);

        vm.prank(admin);
        capCore.setPenaltyBps(LOCK_30_DAYS, PENALTY_30D_BPS, actionId);

        vm.prank(alice);
        capCore.openPosition(1_000 * ONE, LOCK_30_DAYS);

        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 1);

        vm.prank(alice);
        capCore.claim(1);

        assertEq(capCore.totalEmitted(), localMaxEmission);
        assertLe(capCore.totalEmitted(), capCore.maxEmission());
        assertTrue(capCore.emissionFinished());
    }

    function test_Attack_TreasuryDraining() external {
        vm.prank(attacker);
        vm.expectRevert();
        core.withdrawProtocolFees(1 * ONE, bytes32(0));

        vm.prank(attacker);
        vm.expectRevert();
        core.captureSurplus(1 * ONE, bytes32(0));
    }

    function test_Attack_RewardOverClaim() external {
        uint256 pid = _openPositionAs(alice, 1_000 * ONE, LOCK_7_DAYS);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        vm.prank(alice);
        uint256 reward1 = core.claim(pid);
        assertGt(reward1, 0);

        vm.prank(alice);
        vm.expectRevert(StakeLab.NoRewards.selector);
        core.claim(pid);
    }
}
