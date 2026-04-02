// SPDX-License-Identifier: MIT
pragma solidity >0.8.18;

interface IStakeLab {
    struct Position {
        address owner;
        uint256 amount;
        uint256 rewardDebt;
        uint256 startTime;
        uint256 lockDuration;
        bool active;
    }

    event PositionOpened(address indexed user, uint256 indexed positionId, uint256 amount, uint256 lockDuration);
    event RewardClaimed(address indexed user, uint256 indexed positionId, uint256 reward);
    event PositionClosed(
        address indexed user, uint256 indexed positionId, uint256 principalPaid, uint256 rewardPaid, uint256 penalty
    );
    event EmergencyWithdrawal(address indexed user, uint256 indexed positionId, uint256 amount);
    event RewardFunded(address indexed funder, uint256 amount);
    event EmissionUpdated(uint256 oldRate, uint256 newRate);
    event PenaltyUpdated(uint256 lockDuration, uint256 oldPenaltyBps, uint256 newPenaltyBps);
    event ActionQueued(bytes32 indexed actionId, uint256 executeAfter);
    event ActionCancelled(bytes32 indexed actionId);
    event ActionConsumed(bytes32 indexed actionId);
    event SurplusCaptured(uint256 amount);
    event ProtocolFeesWithdrawn(address indexed protocolTreasury, uint256 amount);

    function openPosition(uint256 amount, uint256 lockDuration) external returns (uint256 positionId);
    function claim(uint256 positionId) external returns (uint256 reward);
    function closePosition(uint256 positionId)
        external
        returns (uint256 principalPaid, uint256 rewardPaid, uint256 penalty);
    function emergencyWithdraw(uint256 positionId) external;
    function fundRewards(uint256 amount) external;

    function queueAction(bytes32 actionId) external;
    function setEmissionPerSecond(uint256 newRate, bytes32 actionId) external;
    function setPenaltyBps(uint256 lockDuration, uint256 newPenaltyBps, bytes32 actionId) external;
    function cancelAction(bytes32 actionId) external;
    function withdrawProtocolFees(uint256 amount, bytes32 actionId) external;
    function captureSurplus(uint256 amount, bytes32 actionId) external;

    function previewClaim(uint256 positionId) external view returns (uint256);
    function getPosition(uint256 positionId) external view returns (Position memory);
    function getUnencumberedBalance() external view returns (uint256);
    function getUserPositionCount(address user) external view returns (uint256);
    function getUserPositionsPaginated(address user, uint256 start, uint256 limit)
        external
        view
        returns (uint256[] memory result);
    function pause() external;
    function unpause() external;
}
