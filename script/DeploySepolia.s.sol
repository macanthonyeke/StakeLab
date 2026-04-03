// SPDX-License-Identifier: MIT
pragma solidity >0.8.18;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {StakeLab} from "../src/StakeLab.sol";
import {protocolTreasury} from "../src/Protocol-Treasury.sol";
import {StakeLabToken} from "../src/StakeLabToken.sol";

contract DeploySepolia is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant ONE = 1e18;
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;

    uint256 internal constant LOCK_7_DAYS = 7 days;
    uint256 internal constant LOCK_30_DAYS = 30 days;
    uint256 internal constant LOCK_90_DAYS = 90 days;

    uint256 internal constant PENALTY_7D_BPS = 300;
    uint256 internal constant PENALTY_30D_BPS = 900;
    uint256 internal constant PENALTY_90D_BPS = 1500;

    struct DeployConfig {
        address admin;
        address pauser;
        address treasurer;
        address timelock;
        address guardian;
        address protocolTreasuryAdmin;
        address stakingToken;
        address protocolTreasury;
        address tokenInitialHolder;
        string tokenName;
        string tokenSymbol;
        uint256 minActionDelay;
        uint256 emissionPerSecond;
        uint256 maxEmission;
        uint256 tokenInitialSupply;
        uint256 initialRewardFund;
        bool deployStakingToken;
    }

    function run() external returns (StakeLab core, address stakingToken, address treasuryAddress) {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Run against Ethereum Sepolia");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        DeployConfig memory config = _loadConfig(deployer);

        vm.startBroadcast(deployerPrivateKey);

        if (config.deployStakingToken) {
            StakeLabToken token = new StakeLabToken(
                config.tokenInitialHolder, config.tokenName, config.tokenSymbol, config.tokenInitialSupply
            );
            config.stakingToken = address(token);
        }

        if (config.protocolTreasury == address(0)) {
            config.protocolTreasury = address(new protocolTreasury(config.protocolTreasuryAdmin));
        }

        core = new StakeLab(
            IERC20(config.stakingToken),
            config.admin,
            config.pauser,
            config.treasurer,
            config.timelock,
            config.guardian,
            config.protocolTreasury,
            config.minActionDelay,
            config.emissionPerSecond,
            config.maxEmission
        );

        if (config.initialRewardFund > 0) {
            if (config.treasurer == deployer) {
                uint256 treasuryBalance = IERC20(config.stakingToken).balanceOf(deployer);
                if (treasuryBalance >= config.initialRewardFund) {
                    IERC20(config.stakingToken).forceApprove(address(core), config.initialRewardFund);
                    core.fundRewards(config.initialRewardFund);
                } else {
                    console2.log("Skipped reward funding: deployer balance is lower than INITIAL_REWARD_FUND");
                }
            } else {
                console2.log("Skipped reward funding: TREASURY is not the deployer");
            }
        }

        _configurePenalty(
            core, deployer, config.timelock, config.admin, config.minActionDelay, LOCK_7_DAYS, PENALTY_7D_BPS
        );
        _configurePenalty(
            core, deployer, config.timelock, config.admin, config.minActionDelay, LOCK_30_DAYS, PENALTY_30D_BPS
        );
        _configurePenalty(
            core, deployer, config.timelock, config.admin, config.minActionDelay, LOCK_90_DAYS, PENALTY_90D_BPS
        );

        vm.stopBroadcast();

        stakingToken = config.stakingToken;
        treasuryAddress = config.protocolTreasury;

        console2.log("Deployer", deployer);
        console2.log("StakeLab", address(core));
        console2.log("Staking token", stakingToken);
        console2.log("Protocol treasury", treasuryAddress);
        console2.log("Treasury role", config.treasurer);
        console2.log("Timelock role", config.timelock);
        console2.log("Guardian role", config.guardian);

        if (vm.envOr("WRITE_DEPLOYMENT_JSON", false)) {
            _writeDeploymentJson(deployer, address(core), config);
        }
    }

    function _loadConfig(address deployer) internal view returns (DeployConfig memory config) {
        config.admin = vm.envOr("ADMIN", deployer);
        config.pauser = vm.envOr("PAUSER", config.admin);
        config.treasurer = vm.envOr("TREASURY", deployer);
        config.timelock = vm.envOr("TIMELOCK", deployer);
        config.guardian = vm.envOr("GUARDIAN", deployer);
        config.protocolTreasuryAdmin = vm.envOr("PROTOCOL_TREASURY_ADMIN", config.admin);
        config.stakingToken = vm.envOr("STAKING_TOKEN", address(0));
        config.protocolTreasury = vm.envOr("PROTOCOL_TREASURY", address(0));
        config.tokenInitialHolder = vm.envOr("TOKEN_INITIAL_HOLDER", config.treasurer);
        config.tokenName = vm.envOr("TOKEN_NAME", string("StakeLab Token"));
        config.tokenSymbol = vm.envOr("TOKEN_SYMBOL", string("SLT"));
        config.minActionDelay = vm.envOr("MIN_ACTION_DELAY", uint256(0));
        config.emissionPerSecond = vm.envOr("EMISSION_PER_SECOND", uint256(1e15));
        config.maxEmission = vm.envOr("MAX_EMISSION", uint256(30_000_000 * ONE));
        config.tokenInitialSupply = vm.envOr("TOKEN_INITIAL_SUPPLY", uint256(50_000_000 * ONE));
        config.deployStakingToken = config.stakingToken == address(0);
        config.initialRewardFund =
            vm.envOr("INITIAL_REWARD_FUND", config.deployStakingToken ? uint256(5_000_000 * ONE) : uint256(0));
    }

    function _configurePenalty(
        StakeLab core,
        address deployer,
        address timelock,
        address admin,
        uint256 minActionDelay,
        uint256 lockDuration,
        uint256 penaltyBps
    ) internal {
        if (timelock != deployer) {
            console2.log("Skipped penalty queue: TIMELOCK is not the deployer");
            return;
        }

        bytes32 actionId = keccak256(abi.encode(core.setPenaltyBps.selector, lockDuration, penaltyBps));
        core.queueAction(actionId);

        if (admin == deployer && minActionDelay == 0) {
            core.setPenaltyBps(lockDuration, penaltyBps, actionId);
            console2.log("Configured penalty for lock duration", lockDuration);
            return;
        }

        if (admin != deployer) {
            console2.log("Queued penalty action but did not execute: ADMIN is not the deployer");
        } else {
            console2.log("Queued penalty action but did not execute: MIN_ACTION_DELAY is not zero");
        }

        console2.logBytes32(actionId);
    }

    function _writeDeploymentJson(address deployer, address core, DeployConfig memory config) internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deployments/sepolia.latest.json");
        string memory obj = "deployment";

        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "deployer", deployer);
        vm.serializeAddress(obj, "stakeLab", core);
        vm.serializeAddress(obj, "stakingToken", config.stakingToken);
        vm.serializeAddress(obj, "protocolTreasury", config.protocolTreasury);
        vm.serializeAddress(obj, "admin", config.admin);
        vm.serializeAddress(obj, "pauser", config.pauser);
        vm.serializeAddress(obj, "treasury", config.treasurer);
        vm.serializeAddress(obj, "timelock", config.timelock);
        vm.serializeAddress(obj, "guardian", config.guardian);
        vm.serializeUint(obj, "minActionDelay", config.minActionDelay);
        vm.serializeUint(obj, "emissionPerSecond", config.emissionPerSecond);
        vm.serializeUint(obj, "maxEmission", config.maxEmission);
        string memory json = vm.serializeUint(obj, "initialRewardFund", config.initialRewardFund);

        vm.writeJson(json, path);
    }
}
