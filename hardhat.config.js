require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();
const { subtask } = require("hardhat/config");
const { TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD } = require("hardhat/builtin-tasks/task-names");

// Offline builds: LOCAL_SOLC=1 compiles with the solc-js package in node_modules
// instead of downloading a compiler (useful behind restrictive networks / in CI).
const LOCAL_SOLC = process.env.LOCAL_SOLC === "1";
const SOLC_VERSION = LOCAL_SOLC ? require("solc/package.json").version : "0.8.24";
if (LOCAL_SOLC) {
  subtask(TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD, async () => ({
    compilerPath: require.resolve("solc/soljson.js"),
    isSolcJs: true,
    version: SOLC_VERSION,
    longVersion: require("solc").version(),
  }));
}

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0x0000000000000000000000000000000000000000000000000000000000000001";

module.exports = {
  solidity: {
    version: SOLC_VERSION,
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: "cancun",
      viaIR: true,
    },
  },
  networks: {
    hardhat: {
      accounts: { count: 120 }, // scripts/gas-report.js needs up to 100 endorsers
    },
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL || "https://ethereum-sepolia-rpc.publicnode.com",
      accounts: [PRIVATE_KEY],
      chainId: 11155111,
    },
    amoy: {
      url: process.env.AMOY_RPC_URL || "https://rpc-amoy.polygon.technology/",
      accounts: [PRIVATE_KEY],
      chainId: 80002,
    },
    // 추후 실제 운영 시 사용할 Polygon PoS 메인넷 (지금은 비활성 상태로 참고용)
    polygon: {
      url: process.env.POLYGON_RPC_URL || "https://polygon-rpc.com",
      accounts: [PRIVATE_KEY],
      chainId: 137,
    },
  },
  etherscan: {
    apiKey: {
      sepolia: process.env.ETHERSCAN_API_KEY || "",
      polygonAmoy: process.env.POLYGONSCAN_API_KEY || "",
      polygon: process.env.POLYGONSCAN_API_KEY || "",
    },
    customChains: [
      {
        network: "polygonAmoy",
        chainId: 80002,
        urls: {
          apiURL: "https://api-amoy.polygonscan.com/api",
          browserURL: "https://amoy.polygonscan.com",
        },
      },
    ],
  },
};
