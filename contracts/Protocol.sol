// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "./MockUSDC.sol";
import "hardhat/console.sol";

contract Protocol is CCIPReceiver, OwnerIsCreator {
  error NoMessageReceived(); // Used when trying to access a message but no messages have been received.
  error IndexOutOfBound(uint256 providedIndex, uint256 maxIndex); // Used when the provided index is out of bounds.
  error MessageIdNotExist(bytes32 messageId); // Used when the provided message ID does not exist.
  error NotEnoughBalance(uint256, uint256);
  error NothingToWithdraw(); // Used when trying to withdraw Ether but there's nothing to withdraw.
  error FailedToWithdrawEth(address owner, uint256 value); // Used when the withdrawal of Ether fails.

  event MessageSent(
    bytes32 indexed messageId, // The unique ID of the message.
    uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
    address receiver, // The address of the receiver on the destination chain.
    address borrower, // The borrower's EOA - would map to a depositor on the source chain.
    Client.EVMTokenAmount tokenAmount, // @note specify the Client.EVMTokenAmount struct
    uint256 fees // The fees paid for sending the message.
  );

  event MessageReceived(
    bytes32 indexed messageId, // The unique ID of the message.
    uint64 indexed sourceChainSelector, // The chain selector of the source chain.
    address sender, // The address of the sender from the source chain.
    address depositor, // The EOA of the depositor on the source chain
    Client.EVMTokenAmount tokenAmount // The token amount that was received.
  );

  // Struct to hold details of a message.
  struct MessageIn {
    uint64 sourceChainSelector; // The chain selector of the source chain.
    address sender; // The address of the sender.
    address depositor; // The content of the message => depositor address
    address token; // received token.
    uint256 amount; // received amount.
  }

  // Storage variables.
  bytes32[] public receivedMessages; // Array to keep track of the IDs of received messages.
  mapping(bytes32 => MessageIn) public messageDetail; // Mapping from message ID to MessageIn struct, storing details of each received message.
  mapping(address => mapping(address => uint256)) public deposits; // Depsitor Address => Deposited Token Address ==> amount
  mapping(address => mapping(address => uint256)) public borrowings; // Depsitor Address => Borrowed Token Address ==> amount

  MockUSDC public usdcToken;
  LinkTokenInterface linkToken;

  constructor(address _router, address link) CCIPReceiver(_router) {
    linkToken = LinkTokenInterface(link);
    usdcToken = new MockUSDC();
  }

  // handle a received message => tokens received from Fuji & depositor address (message data)
  // update receivedMessages arr & messageDetail mapping & deposits mapping
  function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
    bytes32 messageId = any2EvmMessage.messageId; // fetch the messageId
    uint64 sourceChainSelector = any2EvmMessage.sourceChainSelector; // fetch the source chain identifier (aka selector)
    address sender = abi.decode(any2EvmMessage.sender, (address)); // abi-decoding of the sender address
    address depositor = abi.decode(any2EvmMessage.data, (address)); // abi-decoding of the depositor's address

    Client.EVMTokenAmount[] memory tokenAmounts = any2EvmMessage.destTokenAmounts;
    address token = tokenAmounts[0].token;
    uint256 amount = tokenAmounts[0].amount;

    console.log("Received messageId: ");
    console.logBytes32(messageId);

    receivedMessages.push(messageId);
    MessageIn memory detail = MessageIn(sourceChainSelector, sender, depositor, token, amount);
    messageDetail[messageId] = detail;

    emit MessageReceived(messageId, sourceChainSelector, sender, depositor, tokenAmounts[0]);

    deposits[depositor][token] += amount;
  }

  //after depositing collateral token, user can borrow USDC
  //instead of msgId, we could also specify transferredToken
  function borrowUSDC(bytes32 msgId, address priceFeedAddress) public returns (uint256) {
    uint256 borrowed = borrowings[msg.sender][address(usdcToken)];
    require(borrowed == 0, "Caller has already borrowed USDC");

    address transferredToken = messageDetail[msgId].token;
    require(transferredToken != address(0), "Caller has not transferred this token");

    uint256 deposited = deposits[msg.sender][transferredToken];
    uint256 borrowable = (deposited * 70) / 100; // 70% collaterization ratio. => 70 wei
    console.log("borrowableInUSDC: ", borrowable);

    // we treat our BnM test token as though it has the same value SNX => Chainlink Pricefeeds.
    // SNX/USD on Sepolia (https://sepolia.etherscan.io/address/0xc0F82A46033b8BdBA4Bb0B0e28Bc2006F64355bC)
    // Docs: https://docs.chain.link/data-feeds/price-feeds/addresses#Sepolia%20Testnet
    //@note get token price from CL feed => 0xc0F82A46033b8BdBA4Bb0B0e28Bc2006F64355bC

    //@todo provide address of a MockAggregatorV3Interface for local testing
    AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddress);
    (, int256 price, , , ) = priceFeed.latestRoundData(); // eg: 135139880 => 1 SNX = 1.35 USD

    //@dont forget to adjust decimals of the returned price
    uint256 price18decimals = uint256(price * (10 ** 10)); // make USD price 18 decimal places from 8 decimal places.

    uint256 borrowableInUSDC = borrowable * price18decimals;
    //console.log("borrowableInUSDC: ", borrowableInUSDC);

    usdcToken.mint(msg.sender, borrowableInUSDC);

    borrowings[msg.sender][address(usdcToken)] = borrowableInUSDC;

    assert(borrowings[msg.sender][address(usdcToken)] == borrowableInUSDC);
    return borrowableInUSDC;
  }

  // Repay the Protocol: pay back USDC & transfer BnM back to source chain (Fuji).
  // Assumes borrower has approved this contract to burn their borrowed USDC token.
  // Assumes borrower has approved this contract to "spend" the transferred BnM token
  // amount = USDC token amount we initially borrowed
  function repayAndSendMessage(uint256 amount, uint64 destinationChain, address receiver, bytes32 msgId) public {
    require(amount >= borrowings[msg.sender][address(usdcToken)], "Repayment amount is less than amount borrowed");

    address transferredToken = messageDetail[msgId].token; //BnM
    uint256 deposited = deposits[msg.sender][transferredToken]; //amount BnM

    uint256 mockUSDCBal = usdcToken.balanceOf(msg.sender);
    require(mockUSDCBal >= amount, "Caller's USDC token balance insufficient for repayment");

    if (usdcToken.allowance(msg.sender, address(this)) < borrowings[msg.sender][address(usdcToken)]) {
      revert("Protocol allowance is less than amount borrowed");
    }

    //@note burn USDC => using burnFrom
    usdcToken.burnFrom(msg.sender, mockUSDCBal);

    borrowings[msg.sender][address(usdcToken)] = 0;

    sendMessage(destinationChain, receiver, transferredToken, deposited);
  }

  //@note send specified token to dest chain & update deposits mapping
  function sendMessage(
    uint64 destinationChainSelector,
    address receiver,
    address tokenToTransfer,
    uint256 transferAmount
  ) internal returns (bytes32 messageId) {
    //@note this is the data we are sending => msg.sender
    address borrower = msg.sender;

    Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
    Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({token: tokenToTransfer, amount: transferAmount});
    tokenAmounts[0] = tokenAmount;

    Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
      receiver: abi.encode(receiver), // ABI-encoded receiver address
      data: abi.encode(borrower), // ABI-encoded string message
      tokenAmounts: tokenAmounts,
      extraArgs: Client._argsToBytes(
        Client.EVMExtraArgsV1({gasLimit: 200_000}) // don't hardcode this
      ),
      feeToken: address(linkToken) // Setting feeToken to LinkToken address, indicating LINK will be used for fees
    });

    IRouterClient router = IRouterClient(this.getRouter());
    uint256 fees = router.getFee(destinationChainSelector, evm2AnyMessage);

    linkToken.approve(address(router), fees);
    require(IERC20(tokenToTransfer).approve(address(router), transferAmount), "Failed to approve router");

    messageId = router.ccipSend(destinationChainSelector, evm2AnyMessage);

    emit MessageSent(messageId, destinationChainSelector, receiver, borrower, tokenAmount, fees);

    deposits[borrower][tokenToTransfer] -= transferAmount;

    return messageId;
  }

  function getNumberOfReceivedMessages() external view returns (uint256 number) {
    return receivedMessages.length;
  }

  function getReceivedMessageDetails(
    bytes32 messageId
  ) external view returns (uint64, address, address, address token, uint256 amount) {
    MessageIn memory detail = messageDetail[messageId];
    //@note make sure, the retrieved message is not empty
    if (detail.sender == address(0)) revert MessageIdNotExist(messageId);
    return (detail.sourceChainSelector, detail.sender, detail.depositor, detail.token, detail.amount);
  }

  function getLastReceivedMessageDetails()
    external
    view
    returns (bytes32 messageId, uint64, address, address, address, uint256)
  {
    if (receivedMessages.length == 0) revert NoMessageReceived();
    messageId = receivedMessages[receivedMessages.length - 1];
    MessageIn memory detail = messageDetail[messageId];
    return (messageId, detail.sourceChainSelector, detail.sender, detail.depositor, detail.token, detail.amount);
  }

  function isChainSupported(uint64 destChainSelector) external view returns (bool supported) {
    return IRouterClient(this.getRouter()).isChainSupported(destChainSelector);
  }

  receive() external payable {}

  function withdraw() public onlyOwner {
    uint256 amount = address(this).balance;
    (bool sent, ) = msg.sender.call{value: amount}("");
    if (!sent) revert FailedToWithdrawEth(msg.sender, amount);
  }

  function withdrawToken(address token) public onlyOwner {
    uint256 amount = IERC20(token).balanceOf(address(this));
    IERC20(token).transfer(msg.sender, amount);
  }
}
