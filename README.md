# StakeLab

StakeLab is a single-token ERC20 staking protocol built around three ideas:
- streamed rewards instead of one-off reward snapshots
- configurable lock periods with early-exit penalties
- explicit solvency accounting so principal, rewards, and protocol fees stay separated

The project is designed as a clean, auditable staking system for testnet deployment and protocol simulation. It includes the core contracts, a production ERC20 token for Sepolia, and a full Foundry test suite covering unit, fuzz, invariant, adversarial, and economic simulation cases.

## What This Project Shows

StakeLab is meant to demonstrate thoughtful protocol engineering rather than just a basic stake-and-unstake flow.

Key design choices:
- single-asset staking to keep the accounting and reward surface simple
- reward streaming through a global accumulator
- early withdrawal penalties as protocol revenue
- timelocked admin actions for sensitive parameter changes
- explicit solvency tracking through liabilities, not just raw token balances
- strong test coverage around failure modes, not only happy paths

## Best Use Case

StakeLab fits best when you want a staking product with:
- one staking token
- one reward token, identical to the staking asset
- predictable emissions with a hard cap
- configurable lock durations
- treasury-safe accounting for rewards, user principal, and fees

It is not intended to be:
- a multi-token farm
- an LP staking system
- a vault strategy product
- a generalized reward distributor

## Architecture

### Core Contracts

- `src/StakeLab.sol`: main staking protocol
- `src/StakeLabToken.sol`: ERC20 token used for real Sepolia deployments
- `src/Protocol-Treasury.sol`: optional treasury receiver for captured surplus and protocol fees
- `src/Interface/IStakeLab.sol`: interface, structs, and events

### Position Model

Each stake is represented as a position with:
- `owner`
- `amount`
- `rewardDebt`
- `startTime`
- `lockDuration`
- `active`

Positions are append-only and identified by incremental IDs. A single wallet can hold multiple simultaneous positions across different lock durations.

### Solvency Model

StakeLab tracks three liabilities:
- `totalPrincipalLiability`: principal owed back to stakers
- `rewardTreasuryLiability`: reward budget promised but not yet paid
- `protocolFeeLiability`: penalties accumulated for protocol treasury

The core solvency invariant is:

```text
stakingToken.balanceOf(address(core)) >=
    totalPrincipalLiability + rewardTreasuryLiability + protocolFeeLiability
```

This is a meaningful design choice: the protocol does not treat its token balance as freely spendable. Instead, it accounts for what portion of that balance is already economically committed.

### Reward Engine

Rewards are streamed over time through a global accumulator:
- `accRewardPerShare`
- updated lazily on state-changing actions
- capped by `maxEmission`
- capped by funded reward inventory

This means emissions cannot exceed either:
- the protocol-wide emission cap, or
- the amount actually funded into the reward treasury

### Lock Durations and Penalties

Users can only open positions in lock durations that governance has explicitly enabled. Each lock duration has a penalty basis-point value configured through `setPenaltyBps`.

That design prevents a common mistake in staking systems where users can bypass intended penalty rules by choosing unsupported durations.

## User Flows

`openPosition(amount, lockDuration)`
- transfers staking tokens into the protocol
- creates a new active position
- increases principal liability

`claim(positionId)`
- pays only accrued rewards
- leaves principal locked
- reduces reward liability

`closePosition(positionId)`
- pays principal and accrued rewards
- applies penalty if closed before maturity
- credits the penalty into protocol fee liability

`emergencyWithdraw(positionId)`
- only while paused
- returns principal only
- forfeits reward payout

## Governance and Safety Controls

### Roles

- `PAUSER_ROLE`: pause and unpause the protocol
- `PARAM_ROLE`: set emission rate and penalty schedule
- `TREASURY_ROLE`: fund rewards, withdraw protocol fees, capture surplus
- `TIMELOCK_ROLE`: queue protected actions
- `GUARDIAN_ROLE`: cancel queued actions

### Timelocked Actions

These sensitive actions require queue-and-execute flow:
- `setEmissionPerSecond`
- `setPenaltyBps`
- `withdrawProtocolFees`
- `captureSurplus`

That reduces the risk of instant admin changes to economics-critical parameters.

## Testing Strategy

This repo includes:
- unit tests in `test/StakeLab.t.sol`
- fuzz tests in `test/StakeLabFuzz.t.sol`
- invariant tests in `test/StakeLabInvariant.t.sol`
- adversarial tests in `test/StakeLabAdversarial.t.sol`
- simulation tests in `test/YieldCoreSimulation.t.sol`

The test suite covers:
- solvency preservation
- emission-cap enforcement
- reward accounting correctness
- treasury underfunding scenarios
- early-exit penalty enforcement
- attempts to drain rewards or bypass lock restrictions
- high-volume open/close/claim activity over time

This is one of the strongest parts of the project because it validates not just features, but protocol behavior under stress and hostile conditions.

## Sepolia Deployment

The deployment flow is built around `script/DeploySepolia.s.sol`.

Default behavior:
- deploy `StakeLabToken` if `STAKING_TOKEN` is not provided
- deploy `Protocol-Treasury` if `PROTOCOL_TREASURY` is not provided
- deploy `StakeLab`
- optionally fund the protocol at deployment time
- optionally queue and execute default lock penalties for 7d, 30d, and 90d durations

### Current Status

There is no current Sepolia deployment recorded in this repo.

Older local Sepolia deployment artifacts were intentionally removed so this repository would not keep advertising obsolete contract addresses as current.

When a fresh deployment is made, document the live addresses here:
- `StakeLabToken`: `0x185b8074b2fa2182742153c62a66fcdb9acfd580`
- `Protocol-Treasury`: `0xc90038ab7b209775ded8e74212f375d2c4bd5943`
- `StakeLab`: `0xb98479a111f157de8a966f054489c49d6dd2b772`

### Recommended Environment

```bash
export SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/OL3XJG8UTLmV0IXER3dvv"
export PRIVATE_KEY="0x..."

export TOKEN_NAME="StakeLab Token"
export TOKEN_SYMBOL="SLT"
export TOKEN_INITIAL_SUPPLY="50000000000000000000000000"
export TOKEN_INITIAL_HOLDER="0xe555c54Ede17BDeC02AFf244ff7fBc44c9f4a177"

export INITIAL_REWARD_FUND="5000000000000000000000000"
export MIN_ACTION_DELAY=0
```

### Optional Environment Overrides

- `STAKING_TOKEN`
- `ADMIN`
- `PAUSER`
- `TREASURY`
- `TIMELOCK`
- `GUARDIAN`
- `PROTOCOL_TREASURY`
- `PROTOCOL_TREASURY_ADMIN`
- `EMISSION_PER_SECOND`
- `MAX_EMISSION`
- `WRITE_DEPLOYMENT_JSON`

### Deploy Command

```bash
forge script script/DeploySepolia.s.sol:DeploySepolia \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast -vvvv
```

If `WRITE_DEPLOYMENT_JSON=true`, the script writes `deployments/sepolia.latest.json`.

Important note:
- automatic reward funding only works when `TREASURY == deployer`, because the script broadcasts from the deployer key
- if treasury is a different address, deploy first and fund rewards in a separate step

## Local Development

Build:

```bash
forge build
```

Test:

```bash
forge test
```

Format:

```bash
forge fmt
```
