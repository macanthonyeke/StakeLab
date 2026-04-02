# StakeLab Protocol 

StakeLab is a staking protocol where users lock a single ERC20 token, earn streamed rewards, and can close positions early with configurable penalties.

This repository contains:
- Core protocol contract: `src/StakeLab.sol` (`StakeLab`)
- Public interface: `src/Interface/IStakeLab.sol`
- Optional treasury vault contract: `src/Protocol-Treasury.sol`
- Unit, fuzz, invariant, and adversarial tests under `test/`

## System Architecture

### Core State
`StakeLab` tracks three liabilities that define solvency:
- `totalPrincipalLiability`: total user principal owed
- `rewardTreasuryLiability`: reward budget still owed
- `protocolFeeLiability`: accumulated penalty fees owed to protocol treasury

The solvency lens is:
`stakingToken.balanceOf(core) >= principal + rewards + protocolFees`

### Position Model
Each position stores:
- `owner`
- `amount`
- `rewardDebt` (snapshot of index at last settle point)
- `startTime`
- `lockDuration`
- `active`

Positions are append-only IDs (`nextPositionId`) and user position IDs are tracked for pagination.

## Staking Lifecycle

### 1) Open Position
`openPosition(amount, lockDuration)`
- Validates non-zero amount
- Validates lock duration is enabled (`validLockDuration[lockDuration] == true`)
- Updates reward index
- Transfers stake token from user to protocol
- Creates active position and increases `totalPrincipalLiability`

### 2) Claim Rewards
`claim(positionId)`
- Only owner of an active position
- Updates reward index
- Computes pending reward from index delta
- Reverts if pending reward is zero
- Reverts if pending reward exceeds `rewardTreasuryLiability`
- Updates position `rewardDebt`, decrements reward liability, transfers reward

### 3) Close Position
`closePosition(positionId)`
- Only owner of an active position
- Updates reward index and computes pending reward
- If closed before lock end, applies configured penalty:
  - `penalty = amount * penaltyBps / 10_000`
  - `principalPaid = amount - penalty`
- If lock matured, no penalty
- Requires reward liquidity (`rewardPaid <= rewardTreasuryLiability`)
- Deactivates position, zeros amount/debt, decrements principal liability
- Credits penalty to `protocolFeeLiability`
- Transfers principal and reward

### 4) Emergency Withdraw (Paused Mode)
`emergencyWithdraw(positionId)` is only available while paused.
- Returns principal only
- No reward payment
- Deactivates position and reduces principal liability

## Reward Emission System

Rewards are streamed by a global accumulator:
- `accRewardPerShare` with precision `1e18`
- Updated lazily in `_updateGlobalIndex()`

Emission for elapsed time:
- `potentialEmission = elapsed * emissionPerSecond`
- Capped by remaining emission cap: `maxEmission - totalEmitted`
- Capped by current reward liability (`rewardTreasuryLiability`)

When remaining emission cap is reached:
- `emissionFinished = true`
- `emissionPerSecond = 0`

`previewClaim(positionId)` simulates the same logic without state mutation.

## Treasury Accounting

### Reward Funding
`fundRewards(amount)` (TREASURY_ROLE):
- Transfers tokens into protocol
- Increases `rewardTreasuryLiability`

### Protocol Fees
Early-exit penalties accumulate in `protocolFeeLiability`.

`withdrawProtocolFees(amount, actionId)` (TREASURY_ROLE + timelocked action):
- Requires `amount <= protocolFeeLiability`
- Decreases fee liability
- Transfers to `protocolTreasury`

### Surplus Capture
`captureSurplus(amount, actionId)` (TREASURY_ROLE + timelocked action):
- Computes `encumbered = principal + rewards + protocolFees`
- Only allows transfer of balance above encumbered amount
- Prevents draining liabilities

## Penalty Mechanics

Penalty schedule is configured by governance per lock duration:
- `setPenaltyBps(lockDuration, newPenaltyBps, actionId)`
- `newPenaltyBps <= 10_000`

Duration activation model:
- A lock duration becomes usable when configured through `setPenaltyBps`
- The function sets `validLockDuration[lockDuration] = true`
- `openPosition` rejects unconfigured durations

This prevents zero-penalty bypasses using arbitrary lock durations.

## Governance and Controls

Access control uses OpenZeppelin `AccessControl`:
- `PAUSER_ROLE`: pause/unpause
- `PARAM_ROLE`: set emission rate, set penalty bps
- `TREASURY_ROLE`: fund rewards, withdraw fees, capture surplus
- `TIMELOCK_ROLE`: queue governance actions
- `GUARDIAN_ROLE`: cancel queued actions

Timelock flow:
1. `queueAction(actionId)` by TIMELOCK_ROLE
2. Wait `MIN_ACTION_DELAY`
3. Execute within `EXECUTION_WINDOW` with the expected `actionId`
4. Guardian may cancel before expiry
5. Cancelled actions have `REQUEUE_COOLDOWN`

## Solvency Invariants (Tested)

The invariant suite (`test/StakeLabInvariant.t.sol`) enforces:
- **Solvency:** contract token balance always backs all liabilities
- **Emission cap:** `totalEmitted <= maxEmission`
- **Reward accounting:** total claimed by handler <= total funded by handler
- **No negative accounting:** liabilities never underflow
- **Position ownership stability**
- **Closed positions cannot be reused**

Adversarial tests (`test/StakeLabAdversarial.t.sol`) additionally stress:
- Reward-draining attempts
- Penalty bypass attempts
- Emission overflow griefing
- Treasury underfunding/starvation scenarios
- Rapid open/close cycles

## Repository Layout

- `src/StakeLab.sol`: main protocol implementation
- `src/Interface/IStakeLab.sol`: protocol interface/events
- `src/Protocol-Treasury.sol`: auxiliary token vault for treasury ops
- `test/StakeLab.t.sol`: lifecycle and access-control unit tests
- `test/StakeLabFuzz.t.sol`: fuzz coverage for amounts, timings, penalties
- `test/StakeLabInvariant.t.sol`: stateful invariant tests
- `test/StakeLabAdversarial.t.sol`: targeted adversarial simulations

## Development

### Build
```bash
forge build
```

### Test
```bash
forge test
```

### Format
```bash
forge fmt
```

## Sepolia Deployment

The repo now includes a Foundry broadcast script at `script/DeploySepolia.s.sol`.

Default behavior:
- deploys a mock ERC20 staking token if `STAKING_TOKEN` is not set
- deploys `protocolTreasury` if `PROTOCOL_TREASURY` is not set
- deploys `StakeLab`
- funds rewards if the deployer is also the treasury role
- queues and executes the 7d, 30d, and 90d penalty configs if the deployer also controls `TIMELOCK` and `ADMIN` and `MIN_ACTION_DELAY=0`

Recommended Sepolia env:

```bash
export SEPOLIA_RPC_URL="https://your-sepolia-rpc"
export PRIVATE_KEY="0x..."
export MIN_ACTION_DELAY=0
```

Optional overrides:
- `STAKING_TOKEN`
- `ADMIN`
- `PAUSER`
- `TREASURY`
- `TIMELOCK`
- `GUARDIAN`
- `PROTOCOL_TREASURY`
- `PROTOCOL_TREASURY_ADMIN`
- `INITIAL_REWARD_FUND`
- `EMISSION_PER_SECOND`
- `MAX_EMISSION`
- `MOCK_TOKEN_NAME`
- `MOCK_TOKEN_SYMBOL`
- `MOCK_TOKEN_TREASURY_MINT`
- `MOCK_TOKEN_DEPLOYER_MINT`

Broadcast to Sepolia:

```bash
forge script script/DeploySepolia.s.sol:DeploySepolia \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast -vvvv
```

If you also want a local deployment summary file, set `WRITE_DEPLOYMENT_JSON=true` before broadcasting. The script will then write `deployments/sepolia.latest.json`.
