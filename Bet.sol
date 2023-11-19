// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract Ownable is Context {
    address private _owner;

    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the initial owner.
     */
    constructor() {
        address initialOwner = msg.sender;
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        if (owner() != _msgSender()) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby disabling any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

contract CustomizedBet is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;

    address public adminAddress; // address of the admin
    uint256 public bufferLockSeconds = 1; // number of seconds for valid execution of a prediction bet
    uint256 public bufferVoteSeconds = 100; // number of seconds for valid vote of a prediction bet
    uint256 public minBetAmount = 10000000000000000; // minimum betting amount (denominated in wei)
    uint256 public maxBetAmount = 10000000000000000000; // maximum betting amount (denominated in wei)

    uint256 public treasuryFee = 1000; // treasury rate (e.g. 200 = 2%, 150 = 1.50%)
    uint256 public treasuryAmount; // treasury amount that was not claimed

    uint256 public constant MAX_TREASURY_FEE = 1000; // 10%

    uint256 public requiredAmountforSelfVote = 1000000000000000;

    uint256 betCount = 0;

    mapping(uint256 => mapping(address => BetInfo)) public ledger;
    mapping(uint256 => Bet) public bets;
    mapping(address => uint256[]) public userBets;


    struct Bet {
        uint256 betId;
        uint256 betType;       // 0 for challenge bet and 1 for market bet.
        address bookMaker;
        string betDetails;
        uint256 startTimestamp;
        uint256 lockTimestamp;
        uint256 closeTimestamp;
        uint256 voteCloseTimestamp;
        uint256 betResult;
        uint256 finished;
        uint256 totalAmount;
        uint256[] positionAmounts;
        string[] positionDetails;
        uint256[] votes;
        uint256 rewardBaseCalAmount;
        uint256 rewardAmount;
    }

    struct BetInfo {
        uint256 position;
        uint256 amount;
        bool voted;
        bool claimed; // default false
    }




    event BetMade(address indexed bookMaker,uint256 betType,uint256 betId, uint256 startTimestamp, uint256 closeTimestamp, string  betDetails, uint256 amount);

    event BetPosition(address indexed sender, uint256  betId, uint256 position, uint256 amount);
    event Claim(address indexed sender, uint256  betId, uint256 amount);

    event EndBet(uint256 betId, uint256 betResult, bool successful);

    event NewAdminAddress(address admin);
    event NewLockBuffer(uint256 bufferLockSeconds);
    event NewVoteBuffer(uint256 bufferLockSeconds);

    event NewMinBetAmount(uint256 changeTime, uint256 minBetAmount);
    event NewMaxBetAmount(uint256 changeTime, uint256 maxBetAmount);
    event NewTreasuryFee(uint256 changeTime, uint256 treasuryFee);

    event RewardsCalculated(
        uint256 betId,
        uint256 rewardBaseCalAmount,
        uint256 rewardAmount,
        uint256 treasuryAmount
    );
    event Recovery(uint256 amount);
    event TreasuryClaim(uint256 amount);
    event Pause(uint256 timestamp);
    event UnPause(uint256 timestamp);

    modifier onlyAdmin() {
        require(msg.sender == adminAddress, "Not admin");
        _;
    }


    modifier notContract() {
        require(!_isContract(msg.sender), "Contract not allowed");
        require(msg.sender == tx.origin, "Proxy contract not allowed");
        _;
    }

    constructor() {
        adminAddress = msg.sender;
    }

    function makeStandardBet(uint256 startTimestamp,uint256 closeTimestamp, string calldata betDetails, uint256 positionCount) public payable onlyOwner {
        require(startTimestamp > block.timestamp, "Start timestamp must be in the future");
        Bet storage mm = bets[betCount];

        mm.betId = betCount;
        mm.betType = 0;
        mm.bookMaker = msg.sender;
        mm.betDetails = betDetails;
        mm.startTimestamp = startTimestamp;
        mm.lockTimestamp = startTimestamp - bufferLockSeconds;
        mm.closeTimestamp = closeTimestamp;
        mm.voteCloseTimestamp = 0;
        mm.totalAmount = 0;

        for(uint256 i = 0; i < positionCount; i++){
            mm.positionAmounts.push(0);
            mm.votes.push(0);
        }
        if(positionCount == 2){
            mm.positionDetails.push("Win");
            mm.positionDetails.push("Fail");
        }
        else if(positionCount == 3){
            mm.positionDetails.push("Home");
            mm.positionDetails.push("Draw");
            mm.positionDetails.push("Away");
        }
        else{
            require(false,"Not a exact Input");
        }

        emit BetMade(msg.sender, mm.betType, betCount, startTimestamp,closeTimestamp, betDetails,0);        betCount = betCount + 1;
    }

    function makeChallengeBet(uint256 startTimestamp,uint256 closeTimestamp, string calldata betDetails, uint256 positionCount) public payable {
        require(startTimestamp > block.timestamp, "Start timestamp must be in the future");
        Bet storage mm = bets[betCount];

        mm.betId = betCount;
        mm.betType = 1;
        mm.bookMaker = msg.sender;
        mm.betDetails = betDetails;
        mm.startTimestamp = startTimestamp;
        mm.lockTimestamp = startTimestamp - bufferLockSeconds;
        mm.closeTimestamp = closeTimestamp;
        mm.voteCloseTimestamp = 0;
        mm.totalAmount = 0;

        for(uint256 i = 0; i < positionCount; i++){
            mm.positionAmounts.push(0);
            mm.votes.push(0);
        }
        if(positionCount == 2){
            mm.positionDetails.push("Win");
            mm.positionDetails.push("Fail");
        }
        else if(positionCount == 3){
            mm.positionDetails.push("Home");
            mm.positionDetails.push("Draw");
            mm.positionDetails.push("Away");
        }
        else{
            require(false,"Not a exact Input");
        }

        emit BetMade(msg.sender, mm.betType, betCount, startTimestamp,closeTimestamp, betDetails,0);
        betCount = betCount + 1;
    }
    function makeMarketBet(uint256 startTimestamp,uint256 closeTimestamp, string calldata betDetails, string calldata myPosition) public payable whenNotPaused nonReentrant notContract  {

        uint256 _amount = msg.value;
        require(startTimestamp > block.timestamp, "Start timestamp must be in the future");
        require(_amount >= minBetAmount, "Bet amount must be greater than minBetAmount");
        require(_amount <= maxBetAmount, "Bet amount must be smaller than maxBetAmount");

        Bet storage mm = bets[betCount];

        mm.betId = betCount;
        mm.betType = 2;
        mm.bookMaker = msg.sender;
        mm.betDetails = betDetails;
        mm.startTimestamp = startTimestamp;
        mm.lockTimestamp = startTimestamp - bufferLockSeconds;
        mm.closeTimestamp = closeTimestamp;
        mm.voteCloseTimestamp = closeTimestamp + bufferVoteSeconds;
        mm.totalAmount = _amount;

        mm.positionAmounts.push(_amount);
        mm.positionDetails.push(myPosition);
        mm.votes.push(0);

        BetInfo storage betInfo = ledger[mm.betId][msg.sender];
        betInfo.position = 0;
        betInfo.amount = _amount;
        userBets[msg.sender].push(mm.betId);

        emit BetMade(msg.sender, mm.betType,betCount, startTimestamp,closeTimestamp, betDetails,_amount);
        betCount = betCount + 1;
    }

    function betWithExistingPosition(uint256 betId, uint256 position) external payable whenNotPaused nonReentrant notContract {
        uint256 _amount = msg.value;
        require(_betable(betId), "Bet not bettable");
        require(_amount >= minBetAmount, "Bet amount must be greater than minBetAmount");
        require(_amount <= maxBetAmount, "Bet amount must be smaller than maxBetAmount");
        require(ledger[betId][msg.sender].amount == 0, "You can not bet coz you have already bet");
        Bet storage mm = bets[betId];


        mm.totalAmount = mm.totalAmount + _amount;
        mm.positionAmounts[position] = mm.positionAmounts[position] + _amount;

        // Update user data
        BetInfo storage betInfo = ledger[betId][msg.sender];
        betInfo.position = position;
        betInfo.amount = _amount;
        userBets[msg.sender].push(betId);

        emit BetPosition(msg.sender, betId, position, _amount);
    }

    function betWithNewPosition(uint256 betId, string calldata position) external payable whenNotPaused nonReentrant notContract {
        uint256 _amount = msg.value;
        require(_betable(betId), "Bet not bettable");
        require(_amount >= minBetAmount, "Bet amount must be greater than minBetAmount");
        require(_amount <= maxBetAmount, "Bet amount must be smaller than maxBetAmount");
        require(ledger[betId][msg.sender].amount == 0, "You can not bet coz you have already bet");

        Bet storage mm = bets[betId];

        require(mm.betType == 2, "Only MarketBet available");

        mm.totalAmount = mm.totalAmount + _amount;
        mm.positionDetails.push(position);
        mm.positionAmounts.push(_amount);
        mm.votes.push(0);
        // Update user data
        uint256 numPosition = mm.positionAmounts.length - 1;
        BetInfo storage betInfo = ledger[betId][msg.sender];
        betInfo.position = numPosition;
        betInfo.amount = _amount;
        userBets[msg.sender].push(betId);

        emit BetPosition(msg.sender, betId, numPosition, _amount);
    }


    function vote(uint256 betId, uint256 position) public payable{
        

        if(bets[betId].betType == 2)
        {
            uint256 _amount = msg.value;
            require(block.timestamp < bets[betId].voteCloseTimestamp, "Vote is finished");
            require(block.timestamp > bets[betId].closeTimestamp, "Bet is not finished yet.");
            require(ledger[betId][msg.sender].amount != 0, "You didn't bet this bet");
            require(ledger[betId][msg.sender].voted == false, "You have already vote");

            uint256 userPosition = ledger[betId][msg.sender].position;


            if(position == userPosition){
                require(_amount == requiredAmountforSelfVote, "If you want to vote on your party, you need to send money");
            }
            Bet storage mm = bets[betId];
            mm.votes[position] = mm.votes[position] + 1;
            ledger[betId][msg.sender].voted = true;
        }
        else{
            bets[betId].voteCloseTimestamp = block.timestamp;
            require(block.timestamp > bets[betId].closeTimestamp, "Bet is not finished yet.");
            require(ledger[betId][msg.sender].voted == false, "You have already vote");

            Bet storage mm = bets[betId];
            mm.votes[position] = mm.votes[position] + 1;
            ledger[betId][msg.sender].voted = true;
            endBet(betId);

        }
        
    }

    function claim(uint256[] calldata betIds) external nonReentrant notContract {
        uint256 reward = 0;
        // Initializes reward

        for (uint256 i = 0; i < betIds.length; i++) {
            require(bets[betIds[i]].startTimestamp != 0, "Bet has not started");
            require(block.timestamp > bets[betIds[i]].voteCloseTimestamp, "Bet has not ended");

            uint256 addedReward = 0;

            // Bet valid, claim rewards
            require(claimable(betIds[i], msg.sender), "Not eligible for claim");
            Bet memory mm = bets[betIds[i]];
            addedReward = (ledger[betIds[i]][msg.sender].amount * mm.rewardAmount) / mm.rewardBaseCalAmount;

            ledger[betIds[i]][msg.sender].claimed = true;
            reward += addedReward;

            emit Claim(msg.sender, betIds[i], addedReward);
        }

        if (reward > 0) {
            (bool sent, ) = address(msg.sender).call{value: reward}("");
            require(sent, "Failed to send reward.");
        }
    }

    function _betable(uint256 betId) internal view returns (bool) {
        return
        bets[betId].startTimestamp != 0 &&
        bets[betId].lockTimestamp != 0 &&
        block.timestamp < bets[betId].startTimestamp &&
        block.timestamp < bets[betId].lockTimestamp;
    }

    function pause() external whenNotPaused onlyAdmin {
        _pause();
        emit Pause(block.timestamp);
    }

    function unpause() external whenPaused onlyAdmin {
        _unpause();

        emit UnPause(block.timestamp);
    }

    function setBufferLockSeconds(uint256 _bufferSeconds) external whenPaused onlyAdmin {
        bufferLockSeconds = _bufferSeconds;

        emit NewLockBuffer(_bufferSeconds);
    }

    function setBufferVoteSeconds(uint256 _bufferSeconds) external whenPaused onlyAdmin {
        bufferVoteSeconds = _bufferSeconds;

        emit NewVoteBuffer(_bufferSeconds);
    }

    function claimTreasury() external nonReentrant onlyAdmin {

        
        uint256 currentTreasuryAmount = treasuryAmount;
        (bool sent, ) = adminAddress.call{value: treasuryAmount}("");
        require(sent, "Failed to claim Treasury");
        treasuryAmount = 0;

        emit TreasuryClaim(currentTreasuryAmount);
    }

    /**
     * @notice Set minBetAmount
     * @dev Callable by admin
     */
    function setMinBetAmount(uint256 _minBetAmount) external whenPaused onlyAdmin {
        require(_minBetAmount != 0, "Must be superior to 0");
        minBetAmount = _minBetAmount;

        emit NewMinBetAmount(block.timestamp, minBetAmount);
    }

    /**
     * @notice Set minBetAmount
     * @dev Callable by admin
     */
    function setRequiredAmountforSelfVote(uint256 _requiredAmountforSelfVote) external whenPaused onlyAdmin {

        requiredAmountforSelfVote = _requiredAmountforSelfVote;

    }

    /**
     * @notice Set minBetAmount
     * @dev Callable by admin
     */
    function setMaxBetAmount(uint256 _maxBetAmount) external whenPaused onlyAdmin {
        require(_maxBetAmount != 0, "Must be superior to 0");
        maxBetAmount = _maxBetAmount;

        emit NewMaxBetAmount(block.timestamp, minBetAmount);
    }


    /**
     * @notice Set treasury fee
     * @dev Callable by admin
     */
    function setTreasuryFee(uint256 _treasuryFee) external whenPaused onlyAdmin {
        require(_treasuryFee <= MAX_TREASURY_FEE, "Treasury fee too high");
        treasuryFee = _treasuryFee;

        emit NewTreasuryFee(block.timestamp, treasuryFee);
    }

    /**
     * @notice Set admin address
     * @dev Callable by owner
     */
    function setAdmin(address _adminAddress) external onlyOwner {
        require(_adminAddress != address(0), "Cannot be zero address");
        adminAddress = _adminAddress;

        emit NewAdminAddress(_adminAddress);
    }

    /**
     * @notice Returns bet betIds and bet information for a user that has participated
     * @param user: user address
     * @param cursor: cursor
     * @param size: size
     */
    function getUserBets(
        address user,
        uint256 cursor,
        uint256 size
    ) external view returns (uint256[] memory, BetInfo[] memory, bool[] memory, uint256)
    {
        uint256 length = size;

        if (length > userBets[user].length - cursor) {
            length = userBets[user].length - cursor;
        }

        uint256[] memory values = new uint256[](length);
        bool[] memory claimables = new bool[](length);
        BetInfo[] memory betInfo = new BetInfo[](length);

        for (uint256 i = 0; i < length; i++) {
            values[i] = userBets[user][cursor + i];
            claimables[i] = claimable(values[i], user);
            betInfo[i] = ledger[values[i]][user];
        }

        return (values, betInfo, claimables, cursor + length);
    }

    function getBets() external view returns(uint256, Bet[] memory)
    {
        uint256 length = betCount;

        Bet[] memory betInfo = new Bet[](length);

        for (uint256 i = 0; i < length; i++) {

            betInfo[i] = bets[i];
        }

        return (length, betInfo);
    }

    /**
     * @notice Returns bet betIds length
     * @param user: user address
     */
    function getUserBetsLength(address user) external view returns (uint256) {
        return userBets[user].length;
    }

    /**
     * @notice Get the claimable stats of specific betId and user account
     * @param betId: betId
     * @param user: user address
     */
    function claimable(uint256 betId, address user) public view returns (bool) {
        BetInfo memory betInfo = ledger[betId][user];
        Bet memory mm = bets[betId];
        if (mm.finished == 0) {
            return false;
        }
        if (mm.finished == 1)
            return   betInfo.amount != 0 && !betInfo.claimed && betInfo.position == mm.betResult;
        else
            return betInfo.amount !=0 && !betInfo.claimed;
    }

    function endBet(uint256 betId) public returns(bool){
        require(bets[betId].lockTimestamp != 0, "Can only end match after match has locked");
        require(block.timestamp >= bets[betId].voteCloseTimestamp, "Can only end match after closeTimestamp");
        require(bets[betId].finished == 0 , "This bet is already finished.");
        Bet storage mm = bets[betId];

        uint256 maxVote = 0;
        uint256 maxCount=0;
        for(uint nIndex = 0 ; nIndex < mm.votes.length; nIndex ++)
        {
            if(maxVote < mm.votes[nIndex])
            {
                maxVote = mm.votes[nIndex];
                maxCount = 1;
            }
            else if(maxVote == mm.votes[nIndex]){
                maxCount = maxCount + 1;
            }
        }
        
        if(maxCount >= 2){
            uint256 treasuryAmt = (mm.totalAmount * 3500) / 10000;
            uint256 rewardAmount = mm.totalAmount - treasuryAmt;
            uint256 rewardBaseCalAmount  = mm.totalAmount;
            mm.finished = 2;
            mm.rewardBaseCalAmount = rewardBaseCalAmount;
            mm.rewardAmount = rewardAmount;

            // Add to treasury
            treasuryAmount += treasuryAmt;


            emit EndBet(betId,0, false);
            return false;
        }
        else{
            uint winnerPosition;
            for(uint nIndex = 0 ; nIndex < mm.votes.length; nIndex ++){
                if(maxVote == mm.votes[nIndex])
                {
                    winnerPosition = nIndex;
                }

            }
            mm.finished = 1;
            mm.betResult = winnerPosition;
            _calculateRewards(betId);
            emit EndBet(betId, winnerPosition, true);
            
        }
        return true;
    }

    

    /**
     * @notice Calculate rewards for match
     * @param betId: betId
     */
    function _calculateRewards(uint256 betId) internal {
        require(bets[betId].rewardBaseCalAmount == 0 && bets[betId].rewardAmount == 0, "Rewards calculated");
        Bet storage mm = bets[betId];
        uint256 rewardBaseCalAmount;
        uint256 treasuryAmt;
        uint256 rewardAmount;

        rewardBaseCalAmount  = mm.positionAmounts[mm.betResult];
        treasuryAmt = (mm.totalAmount * treasuryFee) / 10000;
        rewardAmount = mm.totalAmount - treasuryAmt;

    
        mm.rewardBaseCalAmount = rewardBaseCalAmount;
        mm.rewardAmount = rewardAmount;

        // Add to treasury
        treasuryAmount += treasuryAmt;

        emit RewardsCalculated(betId, rewardBaseCalAmount, rewardAmount, treasuryAmt);
    }

    function _isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

}


