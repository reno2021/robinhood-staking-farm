import { parseUnits } from "ethers";

export const ROBINHOOD_ADMIN_WALLET = "0x9a32e27d1c0961487b64035ea10a4f1087d254bc";
export const DEFAULT_REWARD_TOKEN = "0x0Bd7D308F8E1639FAb988df18A8011f41EAcAD73";

export const DEFAULT_TIER_DURATIONS = [
  0,
  3 * 24 * 60 * 60,
  7 * 24 * 60 * 60,
  30 * 24 * 60 * 60,
  60 * 24 * 60 * 60,
  90 * 24 * 60 * 60,
  365 * 24 * 60 * 60,
  1460 * 24 * 60 * 60
];

export const DEFAULT_TIER_MULTIPLIERS_BPS = [10000, 11000, 12500, 15000, 17500, 20000, 26000, 35000];
export const DEFAULT_POOL_REWARD_PER_SECOND = parseUnits("0.00000000005", 18);

export const INITIAL_POOL_PLACEHOLDERS = [
  {
    name: "WETH/SAITAMA",
    tokenAddress: "0x5ba31b25a1aa4b85d4402894602edd3f9c8e3d7a",
    pairEnv: "LP_WETH_SAITAMA"
  },
  {
    name: "WETH/CASH CAT",
    tokenAddress: "0x020bfc650a365f8bb26819deaabf3e21291018b4",
    pairEnv: "LP_WETH_CASH_CAT"
  },
  {
    name: "WETH/PONS",
    tokenAddress: "0x39dbed3a2bd333467115de45665cc57f813c4571",
    pairEnv: "LP_WETH_PONS"
  },
  {
    name: "WETH/ARTIFICIAL INU",
    tokenAddress: "0x2e8c31162b855a2ffa90f6f8634643ad6f111e18",
    pairEnv: "LP_WETH_ARTIFICIAL_INU"
  }
];
