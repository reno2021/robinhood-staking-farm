import { network } from "hardhat";
import {
  DEFAULT_POOL_REWARD_PER_SECOND,
  DEFAULT_REWARD_TOKEN,
  DEFAULT_TIER_DURATIONS,
  DEFAULT_TIER_MULTIPLIERS_BPS,
  INITIAL_POOL_PLACEHOLDERS
} from "./config/defaultPools.js";

function parseRewardPerSecond(rawValue) {
  if (rawValue === undefined) {
    return DEFAULT_POOL_REWARD_PER_SECOND;
  }

  try {
    return BigInt(rawValue);
  } catch {
    throw new Error("REWARD_PER_SECOND must be an integer wei-per-second value");
  }
}

async function main() {
  const { ethers } = await network.create();
  const farmAddress = process.env.FARM_ADDRESS;
  if (!farmAddress || !ethers.isAddress(farmAddress)) {
    throw new Error("Set FARM_ADDRESS to a deployed RobinhoodStakingFarm address");
  }

  const rewardToken = process.env.REWARD_TOKEN || DEFAULT_REWARD_TOKEN;
  const bonusToken = process.env.BONUS_TOKEN || rewardToken;
  const rewardPerSecond = parseRewardPerSecond(process.env.REWARD_PER_SECOND);

  if (!ethers.isAddress(rewardToken) || !ethers.isAddress(bonusToken)) {
    throw new Error("REWARD_TOKEN and BONUS_TOKEN must be valid addresses");
  }

  const farm = await ethers.getContractAt("RobinhoodStakingFarm", farmAddress);

  for (const pool of INITIAL_POOL_PLACEHOLDERS) {
    const lpToken = process.env[pool.pairEnv];
    if (!lpToken) {
      console.log(`Skipping ${pool.name}: set ${pool.pairEnv} after the DEX pair exists`);
      continue;
    }
    if (!ethers.isAddress(lpToken)) {
      throw new Error(`${pool.pairEnv} is not a valid address`);
    }

    const tx = await farm.addPool(
      lpToken,
      rewardToken,
      bonusToken,
      rewardPerSecond,
      DEFAULT_TIER_DURATIONS,
      DEFAULT_TIER_MULTIPLIERS_BPS,
      false
    );
    await tx.wait();
    console.log(`Added pool ${pool.name} (${lpToken})`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
