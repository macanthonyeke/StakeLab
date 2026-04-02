// SPDX-License-Identifier: MIT
pragma solidity >0.8.18;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import {StakeLab} from "../src/StakeLab.sol";
import {IStakeLab} from "../src/Interface/IStakeLab.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {StakeLabHandler} from "./handlers/StakeLabHandler.t.sol";

contract StakeLabInvariantTest is StdInvariant, Test {
    uint256 internal constant ONE = 1e18;

    uint256 internal constant USER_MINT = 2_000_000 * ONE;
    uint256 internal constant TREASURY_MINT = 100_000_000 * ONE;

    uint256 internal constant INITIAL_REWARD_FUND = 10_000_000 * ONE;
    uint256 internal constant EMISSION_PER_SECOND = 2e15;
    uint256 internal constant MAX_EMISSION = 40_000_000 * ONE;
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
    StakeLabHandler internal handler;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        attacker = makeAddr("attacker");
        treasury = makeAddr("treasury");
        guardian = makeAddr("guardian");

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

        vm.prank(treasury);
        core.fundRewards(INITIAL_REWARD_FUND);

        _queueAndExecuteSetPenalty(LOCK_7_DAYS, PENALTY_7D_BPS);
        _queueAndExecuteSetPenalty(LOCK_30_DAYS, PENALTY_30D_BPS);
        _queueAndExecuteSetPenalty(LOCK_90_DAYS, PENALTY_90D_BPS);

        address[] memory actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = charlie;
        actors[3] = attacker;

        uint256[] memory locks = new uint256[](3);
        locks[0] = LOCK_7_DAYS;
        locks[1] = LOCK_30_DAYS;
        locks[2] = LOCK_90_DAYS;

        handler = new StakeLabHandler(core, token, treasury, actors, locks, INITIAL_REWARD_FUND);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = StakeLabHandler.openPosition.selector;
        selectors[1] = StakeLabHandler.claimRewards.selector;
        selectors[2] = StakeLabHandler.closePosition.selector;
        selectors[3] = StakeLabHandler.fundRewards.selector;
        selectors[4] = StakeLabHandler.warpTime.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _mintAndApprove(address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(core), type(uint256).max);
    }

    function _queueAndExecuteSetPenalty(uint256 lockDuration, uint256 bps) internal {
        bytes32 actionId = keccak256(abi.encode(core.setPenaltyBps.selector, lockDuration, bps));

        vm.prank(timelock);
        core.queueAction(actionId);

        vm.warp(block.timestamp + core.MIN_ACTION_DELAY() + 1);
        vm.roll(block.number + 1);

        vm.prank(admin);
        core.setPenaltyBps(lockDuration, bps, actionId);
    }

    // 1) Solvency: all liabilities remain backed by contract token balance.
    function invariant_Solvency() external view {
        uint256 liabilities =
            core.totalPrincipalLiability() + core.rewardTreasuryLiability() + core.protocolFeeLiability();
        assertGe(token.balanceOf(address(core)), liabilities);
    }

    // 2) Emission cap: emitted rewards never exceed maxEmission.
    function invariant_EmissionCap() external view {
        assertLe(core.totalEmitted(), core.maxEmission());
    }

    // 3) Reward accounting: total claimed rewards cannot exceed total funded rewards.
    function invariant_RewardAccounting() external view {
        assertLe(handler.totalClaimed(), handler.totalFunded());
    }

    // 4) No negative accounting: unsigned liabilities must remain valid and non-underflowed.
    function invariant_NoNegativeAccounting() external view {
        assertGe(core.totalPrincipalLiability(), 0);
        assertGe(core.rewardTreasuryLiability(), 0);
        assertGe(core.protocolFeeLiability(), 0);
    }

    // 5) Position ownership: tracked position owner must remain stable.
    function invariant_PositionOwnership() external view {
        uint256 len = handler.allPositionsLength();
        uint256 toCheck = len > 128 ? 128 : len;

        for (uint256 i = 0; i < toCheck; i++) {
            uint256 pid = handler.positionIdAt(i);
            IStakeLab.Position memory p = core.getPosition(pid);
            assertEq(p.owner, handler.expectedOwner(pid));
        }
    }

    // 6) Closed positions cannot be reactivated/reused.
    function invariant_ClosedPositionsCannotBeReused() external view {
        uint256 len = handler.allPositionsLength();
        uint256 toCheck = len > 128 ? 128 : len;

        for (uint256 i = 0; i < toCheck; i++) {
            uint256 pid = handler.positionIdAt(i);
            if (handler.closedPosition(pid)) {
                IStakeLab.Position memory p = core.getPosition(pid);
                assertFalse(p.active);
                assertEq(p.amount, 0);
                assertEq(p.rewardDebt, 0);
            }
        }
    }
}
