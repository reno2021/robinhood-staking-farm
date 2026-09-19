# Robinhood Chain Dex & Stake

> **Warning:** These contracts are **unaudited**. Review, test, and audit them before any mainnet deployment or funding.

Production-oriented Hardhat project for a multi-pool, MasterChef-like Robinhood Chain staking farm.

## Network and fixed addresses

- Project: **Robinhood Chain Dex & Stake**
- Chain ID: **4663**
- RPC: **https://rpc.mainnet.chain.robinhood.com**
- Initial reward token / wrapped ETH: **0x0Bd7D308F8E1639FAb988df18A8011f41EAcAD73**
- Admin wallet / early-fee recipient: **0x9a32e27d1c0961487b64035ea10a4f1087d254bc**

Initial pool placeholders (LP pair addresses must be supplied after the DEX pair contracts exist):

1. WETH / SAITAMA (`0x5ba31b25a1aa4b85d4402894602edd3f9c8e3d7a` token side)
2. WETH / CASH CAT (`0x020bfc650a365f8bb26819deaabf3e21291018b4` token side)
3. WETH / PONS (`0x39dbed3a2bd333467115de45665cc57f813c4571` token side)
4. WETH / ARTIFICIAL INU (`0x2e8c31162b855a2ffa90f6f8634643ad6f111e18` token side)

## Architecture

`RobinhoodStakingFarm.sol` supports:

- Multiple LP pools with duplicate-LP prevention by default
- Per-pool reward token and bonus token configuration
- Eight lock tiers per pool:
  - flexible / immediate
  - 3 days
  - 7 days
  - 30 days
  - 60 days
  - 90 days
  - 365 days
  - 1460 days
- Multiple positions per user per pool so each deposit can use a different tier
- Explicit reward funding (`fundRewards`) so rewards do **not** accrue unless the pool is funded
- Explicit bonus distribution (`distributeBonusRewards`) so fee proceeds sent to the admin wallet can be deposited and distributed on demand
- Claiming during lock periods
- Early LP withdrawal fee of **9.7%** before maturity on non-flexible tiers, sent to the admin wallet
- Global pause + per-pool pause
- `Ownable2Step` ownership for timelock / multisig-friendly admin transfers
- `ReentrancyGuard` and `SafeERC20`

## Reward model

Each pool has a configurable `rewardPerSecond` base emission. Each tier applies its own multiplier in basis points.

For an active tier:

- `tierRate = rewardPerSecond * tierMultiplierBps / 10_000`
- `tierRewards = elapsedSeconds * tierRate`
- `accRewardPerShare += tierRewards / tierTotalStaked`

Rewards are only accrued for tiers that have stake. Each active tier mints against the pool's configured base rate using its multiplier, so total pool-wide emissions scale with the number of active tiers and their configured multipliers. If a pool has no stakers, time passes without consuming funded rewards. If the configured emission would exceed the pool's funded reward balance, accrual is capped to the funded balance.

Bonus rewards are separate from emissions. The admin wallet must explicitly transfer bonus tokens into the farm through `distributeBonusRewards`. Bonus distributions are allocated pro rata by LP principal across currently staked positions in the selected pool.

## Reward token changes and accounting safety

Reward token changes are intentionally restricted:

- reward tokens are configured **per pool**
- `setPoolRewardToken` is only allowed when the pool has **no active stake** and **no remaining funded reward balance**
- `setPoolBonusToken` is separate, and is only allowed when the pool has **no active stake**

This prevents silently changing the reward asset for existing accounting.

## Lock / claim policy

- Rewards can be claimed **during** the lock period.
- LP principal can be withdrawn at any time.
- Non-flexible tiers charge a **9.7%** early withdrawal fee until maturity.
- After `unlockAt`, withdrawals are fee-free.

## DEX fee separation

This repository implements the staking farm only.

If the DEX routes swap fees / taxes (for example, the requested 0.9% + 0.3% admin-directed flows) to the admin wallet, those funds are **not** assumed to arrive in the farm automatically. The operator must explicitly move proceeds into the farm with:

- `fundRewards(poolId, amount)` for scheduled emissions
- `distributeBonusRewards(poolId, amount)` for pro-rata bonus drops

That separation is deliberate and is reflected in emitted funding events.

## Scripts

Install dependencies:

```bash
npm install
```

Compile:

```bash
npm run compile
```

Run tests:

```bash
npm run test:unit
```

Deploy to Robinhood Chain:

```bash
OWNER_WALLET=0x... \
ADMIN_WALLET=0x9a32e27d1c0961487b64035ea10a4f1087d254bc \
DEPLOYER_PRIVATE_KEY=0x... \
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
npx hardhat run scripts/deployFarm.js --network robinhood
```

Add initial LP pools after pair deployment:

```bash
FARM_ADDRESS=0x... \
DEPLOYER_PRIVATE_KEY=0x... \
LP_WETH_SAITAMA=0x... \
LP_WETH_CASH_CAT=0x... \
LP_WETH_PONS=0x... \
LP_WETH_ARTIFICIAL_INU=0x... \
npx hardhat run scripts/addInitialPools.js --network robinhood
```

Optional overrides:

- `REWARD_TOKEN`
- `BONUS_TOKEN`
- `REWARD_PER_SECOND` (raw wei / second)

## Operational notes

- Fund rewards before expecting any accrual.
- Review and tune `DEFAULT_POOL_REWARD_PER_SECOND` and tier multipliers before production funding.
- Pair addresses are intentionally left as environment-variable inputs because LP contracts do not exist until the DEX factory/router side is deployed.
- No private keys are committed in this repository.
