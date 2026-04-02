// SPDX-License-Identifier: MIT
pragma solidity >0.8.18;

import "forge-std/Test.sol";

import {StakeLab} from "../../src/StakeLab.sol";
import {IStakeLab} from "../../src/Interface/IStakeLab.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract StakeLabHandler is Test {
    uint256 internal constant ONE = 1e18;

    StakeLab public immutable core;
    MockERC20 public immutable token;

    address public immutable treasury;

    address[] internal _actors;
    uint256[] internal _lockDurations;

    mapping(address => uint256[]) internal _userPositions;
    uint256[] internal _allPositions;

    mapping(uint256 => address) public expectedOwner;
    mapping(uint256 => bool) public closedPosition;

    uint256 public totalClaimed;
    uint256 public totalFunded;

    constructor(
        StakeLab core_,
        MockERC20 token_,
        address treasury_,
        address[] memory actors_,
        uint256[] memory lockDurations_,
        uint256 initialFunded
    ) {
        core = core_;
        token = token_;
        treasury = treasury_;
        _actors = actors_;
        _lockDurations = lockDurations_;
        totalFunded = initialFunded;
    }

    function openPosition(uint256 actorSeed, uint256 rawAmount, uint256 lockSeed) external {
        if (core.paused()) return;
        if (_allPositions.length >= 256) return;

        address actor = _actors[actorSeed % _actors.length];
        uint256 lockDuration = _lockDurations[lockSeed % _lockDurations.length];

        uint256 bal = token.balanceOf(actor);
        if (bal == 0) return;

        uint256 amount = bound(rawAmount, ONE, 25_000 * ONE);
        if (amount > bal) amount = bal;

        vm.startPrank(actor);
        try core.openPosition(amount, lockDuration) returns (uint256 pid) {
            _userPositions[actor].push(pid);
            _allPositions.push(pid);
            expectedOwner[pid] = actor;
        } catch {}
        vm.stopPrank();
    }

    function claimRewards(uint256 actorSeed, uint256 indexSeed) external {
        if (core.paused()) return;

        address actor = _actors[actorSeed % _actors.length];
        uint256[] storage userP = _userPositions[actor];
        if (userP.length == 0) return;

        uint256 pid = userP[indexSeed % userP.length];
        IStakeLab.Position memory p = core.getPosition(pid);
        if (!p.active || p.owner != actor) return;

        if (core.previewClaim(pid) == 0) return;

        vm.prank(actor);
        try core.claim(pid) returns (uint256 reward) {
            totalClaimed += reward;
        } catch {}
    }

    function closePosition(uint256 actorSeed, uint256 indexSeed) external {
        if (core.paused()) return;

        address actor = _actors[actorSeed % _actors.length];
        uint256[] storage userP = _userPositions[actor];
        if (userP.length == 0) return;

        uint256 pid = userP[indexSeed % userP.length];

        IStakeLab.Position memory p = core.getPosition(pid);
        if (!p.active || p.owner != actor) return;

        vm.prank(actor);
        try core.closePosition(pid) {
            closedPosition[pid] = true;
        } catch {}
    }

    function fundRewards(uint256 rawAmount) external {
        uint256 bal = token.balanceOf(treasury);
        if (bal == 0) return;

        uint256 amount = bound(rawAmount, ONE, 100_000 * ONE);
        if (amount > bal) amount = bal;

        vm.prank(treasury);
        try core.fundRewards(amount) {
            totalFunded += amount;
        } catch {}
    }

    function warpTime(uint256 rawSeconds) external {
        uint256 jump = bound(rawSeconds, 1 minutes, 14 days);
        vm.warp(block.timestamp + jump);
        vm.roll(block.number + 1);
    }

    function allPositionsLength() external view returns (uint256) {
        return _allPositions.length;
    }

    function positionIdAt(uint256 index) external view returns (uint256) {
        return _allPositions[index];
    }

    function actorAt(uint256 index) external view returns (address) {
        return _actors[index];
    }

    function actorCount() external view returns (uint256) {
        return _actors.length;
    }
}
