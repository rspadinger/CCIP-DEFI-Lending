// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

//the Sender will be deployed to Avalanche Fuji

import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "hardhat/console.sol";

contract Sender is CCIPReceiver, OwnerIsCreator {
  error NoFundsLocked(address msgSender, bool locked);
  error NoMessageReceived(); // Used when trying to access a message but no messages have been received.
  error IndexOutOfBound(uint256 providedIndex, uint256 maxIndex); // Used when the provided index is out of bounds.
  error MessageIdNotExist(bytes32 messageId); // Used when the provided message ID does not exist.
  error NotEnoughBalance(uint256, uint256);
  error NothingToWithdraw(); // Used when trying to withdraw Ether but there's nothing to withdraw.
  error FailedToWithdrawEth(address owner, uint256 value); // Used when the withdrawal of Ether fails.

  // Data Structures
  struct MessageIn {
    uint64 sourceChainSelector; // The chain selector of the source chain.
    address sender; // The address of the sending contract on the source chain.
    address borrower; // EOA sending tokens.
    address token; // received token.
    uint256 amount; // received amount.
  }

  struct Deposit {
    uint256 amount;
    bool locked;
  }

  event MessageSent(
    bytes32 indexed messageId, // The unique ID of the message.
    uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
    address receiver, // The address of the receiver contract on the destination chain.
    address depositor, // EOA sending tokens.
    Client.EVMTokenAmount tokenAmount, // The token amount that was sent.
    uint256 fees // The fees paid for sending the message.
  );

  event MessageReceived(
    bytes32 indexed messageId, // The unique ID of the message.
    uint64 indexed sourceChainSelector, // The chain selector of the source chain.
    address sender, // The address of the sender from the source chain.
    address borrower, // The borrower EOA. Should be a depositor.
    Client.EVMTokenAmount tokenAmount // The token amount that was sent.
  );

  bytes32[] public receivedMessages; // Array to keep track of the IDs of received messages.
  mapping(bytes32 => MessageIn) public messageDetail; // Mapping from message ID to MessageIn struct, storing details of each received message.
  mapping(address => Deposit) public deposits;

  LinkTokenInterface linkToken;

  constructor(address _router, address link) CCIPReceiver(_router) {
    //@note fee token => specify LinkTokenInterface
    linkToken = LinkTokenInterface(link);
  }

  //send a message (addr of sender) & specified token => approve tokens & router.ccipSend
  function sendMessage(
    uint64 destinationChainSelector,
    address receiver,
    address tokenToTransfer,
    uint256 transferAmount
  ) external returns (bytes32 messageId) {
    //@note create EVMTokenAmount
    Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({token: tokenToTransfer, amount: transferAmount});

    Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
    tokenAmounts[0] = tokenAmount;

    // encode the depositor's EOA as  data to be sent in the message.
    bytes memory data = abi.encode(msg.sender);

    //@note create EVM2AnyMessage
    Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
      receiver: abi.encode(receiver), // ABI-encoded receiver contract address
      data: data,
      tokenAmounts: tokenAmounts,
      extraArgs: Client._argsToBytes(
        Client.EVMExtraArgsV1({gasLimit: 200_000}) //this should not be hardcoded
      ),
      feeToken: address(linkToken) // Setting feeToken to LinkToken address, indicating LINK will be used for fees
    });

    IRouterClient router = IRouterClient(this.getRouter());
    uint256 fees = router.getFee(destinationChainSelector, evm2AnyMessage);

    linkToken.approve(address(router), fees);
    IERC20(tokenToTransfer).approve(address(router), transferAmount);

    //@note send message: router.ccipSend
    messageId = router.ccipSend(destinationChainSelector, evm2AnyMessage);

    emit MessageSent(messageId, destinationChainSelector, receiver, msg.sender, tokenAmount, fees);

    return messageId;
  }

  //@note _ccipReceive => called by router => update: receivedMessages & messageDetail
  function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
    bytes32 messageId = any2EvmMessage.messageId; // fetch the messageId
    uint64 sourceChainSelector = any2EvmMessage.sourceChainSelector; // fetch the source chain identifier (aka selector)
    address sender = abi.decode(any2EvmMessage.sender, (address)); // abi-decoding of the sender address
    address borrower = abi.decode(any2EvmMessage.data, (address)); // abi-decoding of the borrower's address

    // Collect tokens transferred. This increases this contract's balance for that Token.
    Client.EVMTokenAmount[] memory tokenAmounts = any2EvmMessage.destTokenAmounts;

    address token = tokenAmounts[0].token;
    uint256 amount = tokenAmounts[0].amount;

    receivedMessages.push(messageId);

    MessageIn memory detail = MessageIn(sourceChainSelector, sender, borrower, token, amount);
    messageDetail[messageId] = detail;

    emit MessageReceived(messageId, sourceChainSelector, sender, borrower, tokenAmounts[0]);
  }

  function getNumberOfReceivedMessages() external view returns (uint256 number) {
    return receivedMessages.length;
  }

  function getLastReceivedMessageDetails()
    external
    view
    returns (bytes32 messageId, uint64, address, address, address, uint256)
  {
    // Revert if no messages have been received
    if (receivedMessages.length == 0) revert NoMessageReceived();

    // Fetch the last received message ID
    messageId = receivedMessages[receivedMessages.length - 1];

    // Fetch the details of the last received message
    MessageIn memory detail = messageDetail[messageId];

    return (messageId, detail.sourceChainSelector, detail.sender, detail.borrower, detail.token, detail.amount);
  }

  function deposit() external payable {
    recordDeposit(msg.sender, msg.value);
  }

  function recordDeposit(address sender, uint256 amount) internal {
    deposits[sender].amount += amount;
    //lock tokens after deposit
    if (!deposits[sender].locked) {
      deposits[sender].locked = true;
    }
  }

  function isChainSupported(uint64 destChainSelector) external view returns (bool supported) {
    //@note verify if a specific chain is supported
    return IRouterClient(this.getRouter()).isChainSupported(destChainSelector);
  }

  //calculate fees in native token (AVAX) for standard message
  function getSendFees(
    uint64 destinationChainSelector,
    address receiver
  ) public view returns (uint256 fees, Client.EVM2AnyMessage memory message) {
    message = Client.EVM2AnyMessage({
      receiver: abi.encode(receiver), // ABI-encoded receiver contract address
      data: abi.encode(msg.sender),
      tokenAmounts: new Client.EVMTokenAmount[](0),
      extraArgs: Client._argsToBytes(
        Client.EVMExtraArgsV1({gasLimit: 200_000}) // Additional arguments, setting gas limit and non-strict sequency mode
      ),
      feeToken: address(0) // Setting feeToken to zero address, indicating native asset will be used for fees
    });

    // Get the fee required to send the message
    fees = IRouterClient(this.getRouter()).getFee(destinationChainSelector, message);
    return (fees, message);
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
