import { network } from "hardhat";
import { ROBINHOOD_ADMIN_WALLET } from "./config/defaultPools.js";

async function main() {
  const { ethers } = await network.create();
  const owner = process.env.OWNER_WALLET || ROBINHOOD_ADMIN_WALLET;
  const adminWallet = process.env.ADMIN_WALLET || ROBINHOOD_ADMIN_WALLET;

  if (!ethers.isAddress(owner) || !ethers.isAddress(adminWallet)) {
    throw new Error("OWNER_WALLET and ADMIN_WALLET must be valid addresses");
  }

  const farm = await ethers.deployContract("RobinhoodStakingFarm", [owner, adminWallet]);
  await farm.waitForDeployment();

  console.log(`RobinhoodStakingFarm deployed to ${await farm.getAddress()}`);
  console.log(`Owner: ${owner}`);
  console.log(`Admin wallet: ${adminWallet}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
