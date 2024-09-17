# CCIP Lending and Borrowing

## Use Case Description

**Contracts:**

-   a "Sender" Contract on Fuji (source chain)
-   a "Protocol" contract on Sepolia (destination chain)

*A user deposits tokenn in Sender contract and transfers that token along with some message data, to the Protocol contract.
*The Protocol contract uses that transferred token as collateral.
\*The user initiates a borrow operation which mints units of the mock stablecoin to lend to the depositor/borrower.

Chainlink CCIP fees are paid using LINK tokens.

The stablecoin in this example repo is a mocked USDC token and we use Chainlink's price feeds to calculate the exchange rate between the deposited token and the Mock USDC stablecoin that is being borrowed.

The borrowed token must then be repaid in full, following which the protocol contract will update the borrowers ledger balances and send a CCIP message back to the source chain.

## Setup - Prerequisites

On the source chain Fuji (where `Sender.sol` is deployed you need):

-   LINK tokens: https://docs.chain.link/resources/link-token-contracts
-   CCIP-BnM Tokens: https://docs.chain.link/ccip/test-tokens#mint-test-tokens
-   Fuji AVAX: https://faucets.chain.link/fuji

On the destination chain Sepolia (where `Protocol.sol` is deployed you need):

-   LINK tokens: https://docs.chain.link/resources/link-token-contracts
-   Sepolia Eth: https://faucets.chain.link/sepolia

## Environment Variables.

We use encrypteed environment variables: https://www.npmjs.com/package/@chainlink/env-enc

Setup the following environment variables:

```
PRIVATE_KEY  // your dev wallet private key
SEPOLIA_RPC_URL // the JSON-RPC Url from Alchemy/Infura etc
AVALANCHE_FUJI_RPC_URL="https://api.avax-test.network/ext/bc/C/rpc"
```

Once you've encrypted your variables (check with `npx env-enc view`) they will automatically be decrypted and injected into your code at runtime.

## Running the Usecase Tasks Locally

Execute the localTest.js script : npx hardhat run scripts/localTest.js

## Running the Usecase Tasks

1. Deploy and fund Sender on Fuji : `npx hardhat setup-sender --network fuji`

2. Deploy & Fund Protocol on Sepolia : `npx hardhat setup-protocol --network sepolia`

Make a note of this contract address. The Protocol controls the interaction with the MockUSDC stablecoin contract - specifically the minting and burning of MockUSDC.

3. Send tokens and data from Fuji to Sepolia :

```
npx hardhat transfer-token \
--network fuji \
--amount 100 \
--sender <<Sender Contract Address on Fuji>> \
--protocol << Protocol Contract Address on Sepolia >> \
--dest-chain sepolia
```

Make a note of the Source Tx Hash. Due to the cross-chain nature of CCIP and the different block confirmation times, sending tokens and data can take between 5 and 15 minutes.

4. Check the message has been received on the destination chain.

Run the Hardhat task to check the content of the tokens and data received on `Protocol.sol` thanks to CCIP:

```
npx hardhat read-message \
--contract <<contract name: either "Sender" or "Protocol" >>  \
--address << contract address >>    \
--message-id <<message Id to read >>    \
--network << network >>
```

5. Initiate the borrowing of the Mock USDC token.

`npx hardhat borrow --network sepolia --protocol <<Protocol Contract on Fuji>>  --message-id << message ID from the CCIP explorer/previous step output >>`

6. Check that your borrowing is recorded on the Protocol contract
   `npx hardhat read-borrowed --protocol <<Protocol Contract on Fuji>> --network sepolia`

7. Repay the borrowing

```
npx hardhat repay --message-id << message id from the fuji to sepolia CCIP call >> \
 --network sepolia \
 --protocol << your protocol.sol address >> \
 --sender << your sender.sol address >>
```

8. Wait for the CCIP transaction to complete.

Go to: https://sepolia.etherscan.io/ and paste in your `Protocol` address. Then click on the Events Tab and if the previous repay task succcessfully excecuted, you'd notice a very recent event. Topic 1 is the Message Id for the Sepolia - Fuji CCIP transaction. Copy that and paste it into the CCIP explorer and wait for "Success".

9. Use the utility functions to cleanup by withdrawing your tokens.

Withdraw your test tokens from the Sender contract with
`npx hardhat withdraw-sender-funds --network fuji --address <<Sender contract address on Fuji>>`

Withdraw your test tokens from the Protocol.sol with
`npx hardhat withdraw-protocol-funds  --network sepolia --address <<Protocol address on Sepolia>>`
