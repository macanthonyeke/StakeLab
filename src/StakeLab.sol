// SPDX-License-Identifier: MIT
pragma solidity >0.8.18;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./Interface/IStakeLab.sol";

contract StakeLab is IStakeLab, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant PARAM_ROLE = keccak256("PARAM_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant TIMELOCK_ROLE = keccak256("TIMELOCK_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant PRECISION = 1e18;

    IERC20 public immutable stakingToken;

    uint256 public immutable MIN_ACTION_DELAY;
    uint256 public constant EXECUTION_WINDOW = 7 days;
    uint256 public constant REQUEUE_COOLDOWN = 1 days;

    uint256 public nextPositionId;
    uint256 public totalPrincipalLiability;
    uint256 public rewardTreasuryLiability;
    uint256 public protocolFeeLiability;
    uint256 public emissionPerSecond;
    uint256 public accRewardPerShare;
    uint256 public lastRewardUpdate;
    uint256 public maxEmission;
    uint256 public totalEmitted;

    bool public emissionFinished;

    address public protocolTreasury;

    mapping(uint256 => Position) private _positions;
    mapping(uint256 => uint256) public penaltyBpsByLockDuration;
    mapping(bytes32 => uint256) public queuedActionExecuteAfter;
    mapping(address => uint256[]) private _userPositions;
    mapping(bytes32 => uint256) public actionCooldownUntil;
    mapping(uint256 => bool) public validLockDuration;

    error ZeroAddress();
    error InvalidAmount();
    error InvalidLockDuration();
    error InvalidPenaltyBps();
    error NotPositionOwner();
    error PositionInactive();
    // error PositionStillLocked();
    error NoRewards();
    error InsufficientRewardTreasury();
    error ActionNotQueued();
    error ActionTooEarly();
    error ActionExpired();
    error InsufficientProtocolFeeAmount();

    constructor(
        IERC20 _stakingToken,
        address admin,
        address pauser,
        address treasurer,
        address timelock,
        address guardian,
        address _protocolTreasury,
        uint256 _minActionDelay,
        uint256 _initialEmissionPerSecond,
        uint256 _maxEmission
    ) {
        if (_protocolTreasury == address(0)) revert ZeroAddress();

        stakingToken = _stakingToken;
        protocolTreasury = _protocolTreasury;
        MIN_ACTION_DELAY = _minActionDelay;
        emissionPerSecond = _initialEmissionPerSecond;
        lastRewardUpdate = block.timestamp;
        maxEmission = _maxEmission;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(PARAM_ROLE, admin);
        _grantRole(TREASURY_ROLE, treasurer);
        _grantRole(TIMELOCK_ROLE, timelock);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    function openPosition(uint256 amount, uint256 lockDuration)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 positionId)
    {
        if (amount == 0) revert InvalidAmount();
        if (!validLockDuration[lockDuration]) revert InvalidLockDuration();

        _updateGlobalIndex();

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        positionId = ++nextPositionId;
        _positions[positionId] = Position({
            owner: msg.sender,
            amount: amount,
            rewardDebt: (amount * accRewardPerShare) / PRECISION,
            startTime: block.timestamp,
            lockDuration: lockDuration,
            active: true
        });

        _userPositions[msg.sender].push(positionId);

        totalPrincipalLiability += amount;

        emit PositionOpened(msg.sender, positionId, amount, lockDuration);
    }

    function claim(uint256 positionId) external whenNotPaused nonReentrant returns (uint256 reward) {
        Position storage p = _positions[positionId];
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (!p.active) revert PositionInactive();

        _updateGlobalIndex();

        reward = _pendingReward(p);
        if (reward == 0) revert NoRewards();
        if (reward > rewardTreasuryLiability) revert InsufficientRewardTreasury();

        p.rewardDebt = (p.amount * accRewardPerShare) / PRECISION;
        rewardTreasuryLiability -= reward;

        stakingToken.safeTransfer(msg.sender, reward);

        emit RewardClaimed(msg.sender, positionId, reward);
    }

    function closePosition(uint256 positionId)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 principalPaid, uint256 rewardPaid, uint256 penalty)
    {
        Position storage p = _positions[positionId];
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (!p.active) revert PositionInactive();

        _updateGlobalIndex();

        uint256 amount = p.amount;

        rewardPaid = _pendingReward(p);

        uint256 lockEnd = p.startTime + p.lockDuration;

        if (block.timestamp < lockEnd) {
            uint256 penaltyBps = penaltyBpsByLockDuration[p.lockDuration];
            penalty = (amount * penaltyBps) / BASIS_POINTS;
            principalPaid = amount - penalty;
        } else {
            principalPaid = amount;
        }

        if (rewardPaid > rewardTreasuryLiability) revert InsufficientRewardTreasury();
        rewardTreasuryLiability -= rewardPaid;

        p.active = false;
        p.amount = 0;
        p.rewardDebt = 0;

        totalPrincipalLiability -= amount;

        if (principalPaid > 0) {
            stakingToken.safeTransfer(msg.sender, principalPaid);
        }

        if (penalty > 0) {
            protocolFeeLiability += penalty;
        }

        if (rewardPaid > 0) {
            stakingToken.safeTransfer(msg.sender, rewardPaid);
        }

        emit PositionClosed(msg.sender, positionId, principalPaid, rewardPaid, penalty);
    }

    function emergencyWithdraw(uint256 positionId) external whenPaused nonReentrant {
        Position storage p = _positions[positionId];

        if (p.owner != msg.sender) revert NotPositionOwner();
        if (!p.active) revert PositionInactive();

        uint256 amount = p.amount;

        p.active = false;
        p.amount = 0;
        p.rewardDebt = 0;

        totalPrincipalLiability -= amount;

        stakingToken.safeTransfer(msg.sender, amount);

        emit EmergencyWithdrawal(msg.sender, positionId, amount);
    }

    function fundRewards(uint256 amount) external onlyRole(TREASURY_ROLE) nonReentrant {
        if (amount == 0) revert InvalidAmount();

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardTreasuryLiability += amount;

        emit RewardFunded(msg.sender, amount);
    }

    function queueAction(bytes32 actionId) external onlyRole(TIMELOCK_ROLE) {
        uint256 executeAfter = block.timestamp + MIN_ACTION_DELAY;

        if (block.timestamp < actionCooldownUntil[actionId]) revert ActionTooEarly();

        queuedActionExecuteAfter[actionId] = executeAfter;

        emit ActionQueued(actionId, executeAfter);
    }

    function cancelAction(bytes32 actionId) external onlyRole(GUARDIAN_ROLE) {
        uint256 executeAfter = queuedActionExecuteAfter[actionId];
        if (executeAfter == 0) revert ActionNotQueued();

        if (block.timestamp > executeAfter + EXECUTION_WINDOW) revert ActionExpired();

        delete queuedActionExecuteAfter[actionId];

        actionCooldownUntil[actionId] = block.timestamp + REQUEUE_COOLDOWN;

        emit ActionCancelled(actionId);
    }

    function setEmissionPerSecond(uint256 newRate, bytes32 actionId) external onlyRole(PARAM_ROLE) {
        bytes32 expectedActionId = keccak256(abi.encode(this.setEmissionPerSecond.selector, newRate));

        _consumeQueuedAction(actionId, expectedActionId);

        _updateGlobalIndex();

        uint256 oldRate = emissionPerSecond;
        emissionPerSecond = newRate;

        emit EmissionUpdated(oldRate, newRate);
    }

    function setPenaltyBps(uint256 lockDuration, uint256 newPenaltyBps, bytes32 actionId)
        external
        onlyRole(PARAM_ROLE)
    {
        if (lockDuration == 0) revert InvalidLockDuration();
        if (newPenaltyBps > BASIS_POINTS) revert InvalidPenaltyBps();

        bytes32 expectedActionId = keccak256(abi.encode(this.setPenaltyBps.selector, lockDuration, newPenaltyBps));

        _consumeQueuedAction(actionId, expectedActionId);

        uint256 oldPenaltyBps = penaltyBpsByLockDuration[lockDuration];
        penaltyBpsByLockDuration[lockDuration] = newPenaltyBps;
        validLockDuration[lockDuration] = true;

        emit PenaltyUpdated(lockDuration, oldPenaltyBps, newPenaltyBps);
    }

    function withdrawProtocolFees(uint256 amount, bytes32 actionId) external onlyRole(TREASURY_ROLE) nonReentrant {
        if (amount > protocolFeeLiability) revert InsufficientProtocolFeeAmount();
        if (amount == 0) revert InvalidAmount();

        bytes32 expectedActionId = keccak256(abi.encode(this.withdrawProtocolFees.selector, amount));

        _consumeQueuedAction(actionId, expectedActionId);

        protocolFeeLiability -= amount;

        stakingToken.safeTransfer(protocolTreasury, amount);

        emit ProtocolFeesWithdrawn(protocolTreasury, amount);
    }

    function captureSurplus(uint256 amount, bytes32 actionId) external onlyRole(TREASURY_ROLE) nonReentrant {
        bytes32 expectedActionId = keccak256(abi.encode(this.captureSurplus.selector, amount));

        _consumeQueuedAction(actionId, expectedActionId);

        uint256 balance = stakingToken.balanceOf(address(this));

        uint256 encumbered = totalPrincipalLiability + rewardTreasuryLiability + protocolFeeLiability;

        if (balance <= encumbered) revert InvalidAmount();

        uint256 surplus = balance - encumbered;

        if (amount > surplus) revert InvalidAmount();

        stakingToken.safeTransfer(protocolTreasury, amount);

        emit SurplusCaptured(amount);
    }

    function previewClaim(uint256 positionId) public view returns (uint256) {
        Position memory p = _positions[positionId];
        if (!p.active) return 0;

        uint256 projectedAcc = accRewardPerShare;

        if (block.timestamp > lastRewardUpdate && totalPrincipalLiability > 0 && !emissionFinished) {
            uint256 elapsed = block.timestamp - lastRewardUpdate;

            uint256 potentialEmission = elapsed * emissionPerSecond;

            uint256 remainingEmission = maxEmission - totalEmitted;

            if (potentialEmission > remainingEmission) {
                potentialEmission = remainingEmission;
            }

            if (potentialEmission > rewardTreasuryLiability) {
                potentialEmission = rewardTreasuryLiability;
            }

            projectedAcc += (potentialEmission * PRECISION) / totalPrincipalLiability;
        }

        uint256 accrued = (p.amount * projectedAcc) / PRECISION;

        if (accrued <= p.rewardDebt) return 0;

        return accrued - p.rewardDebt;
    }

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return _positions[positionId];
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function getUnencumberedBalance() public view returns (uint256) {
        uint256 balance = stakingToken.balanceOf(address(this));
        uint256 encumbered = totalPrincipalLiability + rewardTreasuryLiability + protocolFeeLiability;
        if (balance <= encumbered) return 0;

        return balance - encumbered;
    }

    function getUserPositionsPaginated(address user, uint256 start, uint256 limit)
        external
        view
        returns (uint256[] memory result)
    {
        uint256 length = _userPositions[user].length;

        if (limit == 0) {
            return new uint256[](0);
        }

        if (start >= length) {
            return new uint256[](0);
        }

        uint256 remaining = length - start;
        uint256 resultLength = limit > remaining ? remaining : limit;
        result = new uint256[](resultLength);

        for (uint256 i = 0; i < resultLength; i++) {
            result[i] = _userPositions[user][start + i];
        }

        return result;
    }

    function getUserPositionCount(address user) external view returns (uint256) {
        return _userPositions[user].length;
    }

    function _updateGlobalIndex() internal {
        if (block.timestamp <= lastRewardUpdate) {
            return;
        }

        if (totalPrincipalLiability == 0) {
            lastRewardUpdate = block.timestamp;
            return;
        }

        if (emissionFinished) {
            lastRewardUpdate = block.timestamp;
            return;
        }

        // if (totalEmitted >= maxEmission) {
        //     emissionFinished = true;
        //     emissionPerSecond = 0;
        //     lastRewardUpdate = block.timestamp;
        //     return;
        // }

        uint256 elapsed = block.timestamp - lastRewardUpdate;

        uint256 potentialEmission = elapsed * emissionPerSecond;

        uint256 remainingEmission = maxEmission - totalEmitted;

        if (potentialEmission >= remainingEmission) {
            potentialEmission = remainingEmission;
            emissionFinished = true;
            emissionPerSecond = 0;
        }

        if (potentialEmission > rewardTreasuryLiability) {
            potentialEmission = rewardTreasuryLiability;
        }

        if (potentialEmission > 0) {
            accRewardPerShare += (potentialEmission * PRECISION) / totalPrincipalLiability;

            totalEmitted += potentialEmission;
        }

        lastRewardUpdate = block.timestamp;
    }

    function _pendingReward(Position memory p) internal view returns (uint256) {
        if (!p.active) return 0;

        uint256 accrued = (p.amount * accRewardPerShare) / PRECISION;

        if (accrued <= p.rewardDebt) return 0;

        return accrued - p.rewardDebt;
    }

    function _consumeQueuedAction(bytes32 actionId, bytes32 expectedActionId) internal {
        if (actionId != expectedActionId) revert ActionNotQueued();

        uint256 executeAfter = queuedActionExecuteAfter[actionId];
        if (executeAfter == 0) revert ActionNotQueued();
        if (block.timestamp < executeAfter) revert ActionTooEarly();
        if (block.timestamp > executeAfter + EXECUTION_WINDOW) revert ActionExpired();

        delete queuedActionExecuteAfter[actionId];
        emit ActionConsumed(actionId);
    }
}
