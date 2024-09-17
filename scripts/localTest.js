async function main() {
    ;[deployer] = await ethers.getSigners()
    let tx, txResp, result, borrowings

    const mockV3AggregatorFactory = await ethers.getContractFactory("MockV3Aggregator")
    const mockV3Aggregator = await mockV3AggregatorFactory.deploy(8, 135139880)
    //console.log("mockV3Aggregator: ", mockV3Aggregator.address)
    // await mockV3Aggregator.updateAnswer(155139880)
    // console.log("Price: ", (await mockV3Aggregator.latestRoundData())["answer"])

    //setup the CCIP simulator => https://github.com/smartcontractkit/chainlink-local/blob/main/test/smoke/ccip/UnsafeTokenAndDataTransfer.spec.ts
    //https://github.com/smartcontractkit/ccip-starter-kit-hardhat/blob/main/test/no-fork/Example1.spec.ts
    const localSimulatorFactory = await ethers.getContractFactory("CCIPLocalSimulator")
    const localSimulator = await localSimulatorFactory.deploy()

    const config = ({
        chainSelector_: bigint,
        sourceRouter_: string,
        destinationRouter_: string,
        wrappedNative_: string,
        linkToken_: string,
        ccipBnM_: string,
        ccipLnM_: string,
    } = await localSimulator.configuration())

    //attach router contracts
    const mockCcipRouterFactory = await hre.ethers.getContractFactory("MockCCIPRouter")
    const sourceCcipRouter = mockCcipRouterFactory.attach(config.sourceRouter_)
    //const sourceCcipRouterAddress = await sourceCcipRouter.address == config.sourceRouter_
    const destCcipRouter = mockCcipRouterFactory.attach(config.destinationRouter_)

    //******************************************************************************************
    // 1: Deploy and fund Sender on SOURCE CHAIN => fund with BnM & LINK
    //******************************************************************************************

    console.log("\n****** 1: Deploy and fund Sender on SOURCE CHAIN => fund with BnM & LINK ******")

    const TOKEN_TRANSFER_AMOUNT = "0.0001"
    const LINK_FUND_AMOUNT = ethers.utils.parseEther("50")

    const senderContract = await ethers.deployContract("Sender", [config.sourceRouter_, config.linkToken_]) // ...], {value: ethers.parseEther("0.001") })
    await senderContract.deployed()

    console.log("Sender deployed to:", senderContract.address)

    const ccipBnMFactory = await ethers.getContractFactory("BurnMintERC677Helper")
    const ccipBnM = ccipBnMFactory.attach(config.ccipBnM_)

    await ccipBnM.drip(senderContract.address)
    console.log(
        `Funded Sender contract with ${ethers.utils.formatEther(
            await ccipBnM.balanceOf(senderContract.address)
        )} CCIP-BnM`
    )

    const linkTokenFactory = await ethers.getContractFactory("LinkToken")
    const linkToken = linkTokenFactory.attach(config.linkToken_)

    await localSimulator.requestLinkFromFaucet(senderContract.address, LINK_FUND_AMOUNT)
    //console.log("Bal: ", await linkToken.balanceOf(senderContract.address))
    console.log(`Funded Sender contract with ${ethers.utils.formatEther(LINK_FUND_AMOUNT)} LINK`)

    //******************************************************************************************
    // 2: Deploy & Fund Protocol on Sepolia => fund with BnM & LINK
    //******************************************************************************************

    console.log("\n ****** 2: Deploy & Fund Protocol on Sepolia => fund with BnM & LINK ******")

    const protocolContract = await ethers.deployContract("Protocol", [config.destinationRouter_, config.linkToken_])
    await protocolContract.deployed()

    console.log("\nProtocol deployed to:", protocolContract.address)

    await localSimulator.requestLinkFromFaucet(protocolContract.address, LINK_FUND_AMOUNT)
    console.log(`Funded Protocol contract with ${ethers.utils.formatEther(LINK_FUND_AMOUNT)} LINK`)

    const usdcToken = await protocolContract.usdcToken()
    console.log(`MockUSDC contract is deployed to ${usdcToken}`)

    const mockUsdcFactory = await ethers.getContractFactory("MockUSDC")
    const mockUsdcToken = await mockUsdcFactory.attach(usdcToken)

    //await linkToken.connect(senderContract).approve(sourceCcipRouter, LINK_FUND_AMOUNT)

    //******************************************************************************************
    // 3: Send tokens and data from Fuji to Sepolia (From Sender.sol to Protocol.sol) : 100 wei
    //******************************************************************************************

    console.log(
        "\n ****** 3: Send tokens and data from Fuji to Sepolia (From Sender.sol to Protocol.sol) : 100 wei ******"
    )

    const destChainSelector = "16015286601757825753"
    const amountToSend = 100

    const sendTokensTx = await senderContract.sendMessage(
        destChainSelector,
        protocolContract.address,
        config.ccipBnM_,
        amountToSend,
        {
            gasLimit: 600000,
        }
    )

    const resp = await sendTokensTx.wait()

    //******************************************************************************************
    // 4: Check the message has been received on the destination chain
    //******************************************************************************************

    console.log("\n ****** 4: Check the message has been received on the destination chain. ******")

    let messageId = (await protocolContract.getLastReceivedMessageDetails())["messageId"]
    //console.log(`MessageId received by Protocol contract: ${messageId}`)

    //let filter = protocolContract.filters.MessageReceived(null, null, null, null, null)
    let logs = await protocolContract.queryFilter("MessageReceived", "latest", "latest") // Or: ...queryFilter(filter,...
    //console.log("Logs (messageId): ", logs[0].args["messageId"])

    const [sourceChainSelector, senderContr, depositorEOA, transferredToken, amountTransferred] =
        await protocolContract.messageDetail(messageId)

    console.log(`\nMessage details received in Protocol contract: 
    messageId: ${messageId},
    sourceChainSelector: ${sourceChainSelector},
    senderContract: ${senderContr},
    depositorEOA: ${depositorEOA},
    transferredToken: ${transferredToken},
    amountTransferred: ${amountTransferred}
    `)

    const deposit = await protocolContract.deposits(depositorEOA, transferredToken)
    const borrowedToken = await protocolContract.usdcToken()
    borrowings = await protocolContract.borrowings(depositorEOA, borrowedToken)

    console.log(`Deposit recorded on Protocol: 
    Depositor: ${depositorEOA}, 
    Token: ${transferredToken}, 
    Deposited Amount: ${deposit},
    Borrowing: ${borrowings}
    `)

    //******************************************************************************************
    // 5: Initiate the borrow/swap of the deposited token for the Mock USDC token
    //******************************************************************************************

    console.log("\n ****** 5: Initiate the borrow/swap of the deposited token for the Mock USDC token ******")

    let borrowerBalance = await protocolContract.borrowings(depositorEOA, usdcToken)

    const borrowTx = await protocolContract.borrowUSDC(messageId, mockV3Aggregator.address)
    await borrowTx.wait()

    borrowings = await protocolContract.borrowings(depositorEOA, usdcToken)
    const borrowerTokenBal = await mockUsdcToken.balanceOf(deployer.address)

    console.log(`
    Total Borrowings: '${ethers.utils.formatEther(borrowings)}'.
    Borrower Token Balance: '${ethers.utils.formatEther(borrowerTokenBal)}'`)

    //******************************************************************************************
    // 6: Repay the borrowing
    //******************************************************************************************

    console.log("\n ****** 6: Repay the borrowing ******")

    const borrowerUSDCBal = await mockUsdcToken.balanceOf(deployer.address)
    borrowerBalance = await protocolContract.borrowings(deployer.address, mockUsdcToken.address)
    console.log(
        "\nBorrowings: ",
        ethers.utils.formatEther(borrowerBalance),
        "\nRepayment amount: ",
        ethers.utils.formatEther(borrowerUSDCBal)
    )

    if (borrowerBalance.toString() !== borrowerUSDCBal.toString()) {
        throw Error(
            `Borrower's Mock USDC balance '${borrowerUSDCBal}' does not match the amount borrowed from Protocol '${borrowerBalance}'`
        )
    }

    if (borrowerBalance.toString() == "0") {
        console.info("\nBorrower has no outstanding borrowings.  Nothing to repay.")
        return
    }

    const approveBurnTx = await mockUsdcToken.connect(deployer).approve(protocolContract.address, borrowerUSDCBal)
    await approveBurnTx.wait()

    console.log(`\nRepaying borrowed token...`)
    const repayTx = await protocolContract.repayAndSendMessage(
        borrowerUSDCBal,
        sourceChainSelector,
        senderContract.address,
        messageId
    )
    await repayTx.wait()

    const updatedBorrowerUSDCBal = await mockUsdcToken.balanceOf(deployer.address)
    const usdcTotalSupply = await mockUsdcToken.totalSupply()

    console.log(
        `\nBorrower's MockUSDC token balance is now  '${updatedBorrowerUSDCBal}' and the token's total supply is now ${usdcTotalSupply}`
    )
}

main()
