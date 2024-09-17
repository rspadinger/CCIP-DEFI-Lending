require("@nomicfoundation/hardhat-toolbox")
require("hardhat-contract-sizer")
require("@openzeppelin/hardhat-upgrades")
require("./tasks")

//require("dotenv").config()

//@note use encryption
require("@chainlink/env-enc").config()
const { networks } = require("./networks")

const { PRIVATE_KEY_LOCAL } = process.env

// Enable gas reporting (optional)
const REPORT_GAS = process.env.REPORT_GAS?.toLowerCase() === "true" ? true : false

const SOLC_SETTINGS = {
    optimizer: {
        enabled: true,
        runs: 1_000,
    },
}

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
    defaultNetwork: "localhost",
    solidity: {
        compilers: [
            {
                version: "0.8.24",
                settings: SOLC_SETTINGS,
            },
            {
                version: "0.8.19",
                settings: SOLC_SETTINGS,
            },
        ],
    },
    networks: {
        hardhat: {
            allowUnlimitedContractSize: true,
            accounts: PRIVATE_KEY_LOCAL
                ? [
                      {
                          privateKey: PRIVATE_KEY_LOCAL,
                          balance: "10000000000000000000000",
                      },
                  ]
                : [],
        },
        //@note add all other networks
        ...networks,
    },
    etherscan: {
        // npx hardhat verify --network <NETWORK> <CONTRACT_ADDRESS> <CONSTRUCTOR_PARAMETERS>
        // to get exact network names: npx hardhat verify --list-networks
        apiKey: {
            sepolia: networks.sepolia.verifyApiKey,
            avalancheFujiTestnet: networks.fuji.verifyApiKey,
        },
    },
    gasReporter: {
        enabled: REPORT_GAS,
        currency: "USD",
        outputFile: "gas-report.txt",
        noColors: true,
    },
    contractSizer: {
        runOnCompile: false,
        only: ["FunctionsConsumer", "AutomatedFunctionsConsumer", "FunctionsBillingRegistry"],
    },
    paths: {
        sources: "./contracts",
        tests: "./test",
        cache: "./build/cache",
        artifacts: "./build/artifacts",
    },
}
