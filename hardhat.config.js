import { createRequire } from "node:module";
import hardhatEthers from "@nomicfoundation/hardhat-ethers";
import hardhatEthersChaiMatchers from "@nomicfoundation/hardhat-ethers-chai-matchers";
import hardhatMocha from "@nomicfoundation/hardhat-mocha";
import hardhatNetworkHelpers from "@nomicfoundation/hardhat-network-helpers";
import "dotenv/config";
import { defineConfig } from "hardhat/config";

const require = createRequire(import.meta.url);
const solcPath = require.resolve("solc/soljson.js");
const ROBINHOOD_RPC_URL = process.env.ROBINHOOD_RPC_URL || "https://rpc.mainnet.chain.robinhood.com";
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;

export default defineConfig({
  plugins: [hardhatEthers, hardhatEthersChaiMatchers, hardhatMocha, hardhatNetworkHelpers],
  solidity: {
    profiles: {
      default: {
        version: "0.8.37",
        path: solcPath,
        preferWasm: true,
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      }
    }
  },
  networks: {
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1"
    },
    robinhood: {
      type: "http",
      chainType: "l1",
      url: ROBINHOOD_RPC_URL,
      chainId: 4663,
      accounts: DEPLOYER_PRIVATE_KEY ? [DEPLOYER_PRIVATE_KEY] : []
    }
  },
  test: {
    mocha: {
      timeout: 120000
    }
  }
});
