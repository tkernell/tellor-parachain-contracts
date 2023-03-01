// SPDX-License-Identifier: MIT
pragma solidity 0.8.3;

import "lib/tellor/interfaces/IERC20.sol";
import {Parachain} from "./Parachain.sol";


interface IParachainStaking {
    function depositParachainStake(uint32 _paraId, bytes calldata _account, uint256 _amount) external;
    function requestParachainStakeWithdrawal(uint32 _paraId, uint256 _amount) external;
    function confirmParachainStakeWidthrawRequest(uint32 _paraId, address _staker, uint256 _amount) external;
    function withdrawParachainStake(uint32 _paraId, address _staker, uint256 _amount) external;
    function slashParachainReporter(uint32 _paraId, address _reporter, address _recipient) external returns (uint256);
    function getTokenAddress() external view returns (address);
 
}


/**
 @author Tellor Inc.
 @title ParachainStaking
 @dev This contract handles staking and slashing of stakers who enable reporting
 * linked accounts on oracle consumer parachains. This contract is controlled
 * by a single address known as 'governance', which could be an externally owned
 * account or a contract, allowing for a flexible, modular design.
*/
contract ParachainStaking is Parachain {
    // Storage
    IERC20 public token; // token used for staking and rewards
    address public governance; // address with ability to remove values and slash reporters
    address public owner; // contract deployer, can call init function once
    uint256 public totalStakeAmount; // total amount of tokens locked in contract (via stake)
    uint256 public totalStakers; // total number of stakers with at least stakeAmount staked, not exact
    uint256 public toWithdraw; //amountLockedForWithdrawal

    mapping(address => StakeInfo) private stakerDetails; // mapping from a persons address to their staking info
    mapping(uint32 => mapping(address => ParachainStakeInfo)) private parachainStakerDetails;

    // Structs
    struct Report {
        uint256[] timestamps; // array of all newValueTimestamps reported
        mapping(uint256 => uint256) timestampIndex; // mapping of timestamps to respective indices
        mapping(uint256 => uint256) timestampToBlockNum; // mapping of timestamp to block number
        mapping(uint256 => bytes) valueByTimestamp; // mapping of timestamps to values
        mapping(uint256 => address) reporterByTimestamp; // mapping of timestamps to reporters
        mapping(uint256 => bool) isDisputed;
    }

    struct StakeInfo {
        uint256 startDate; // stake or withdrawal request start date
        uint256 stakedBalance; // staked token balance
        uint256 lockedBalance; // amount locked for withdrawal
        uint256 rewardDebt; // used for staking reward calculation
        uint256 reporterLastTimestamp; // timestamp of reporter's last reported value
        uint256 reportsSubmitted; // total number of reports submitted by reporter
        uint256 startVoteCount; // total number of governance votes when stake deposited
        uint256 startVoteTally; // staker vote tally when stake deposited
        bool staked; // used to keep track of total stakers
        mapping(bytes32 => uint256) reportsSubmittedByQueryId; // mapping of queryId to number of reports submitted by reporter
    }

    struct ParachainStakeInfo {
        StakeInfo _stakeInfo;
        bytes _account;
        uint256 _lockedBalanceConfirmed;
    }

    // Events
    event NewStaker(address indexed _staker, uint256 indexed _amount);
    event ReporterSlashed(
        address indexed _reporter,
        address _recipient,
        uint256 _slashAmount
    );
    event StakeWithdrawn(address _staker);
    event StakeWithdrawRequested(address _staker, uint256 _amount);
    event NewParachainStaker(uint32 _paraId, address _staker, bytes _account, uint256 _amount);
    event ParachainReporterSlashed(uint32 _paraId, address _reporter, address _recipient, uint256 _slashAmount);
    event ParachainStakeWithdrawRequested(uint32 _paraId, bytes _account, uint256 _amount);
    event ParachainStakeWithdrawRequestConfirmed(uint32 _paraId, address _staker, uint256 _amount);
    event ParachainStakeWithdrawn(uint32 _paraId, address _staker);
    event ParachainValueRemoved(uint32 _paraId, bytes32 _queryId, uint256 _timestamp);

    // Functions
    /**
     * @dev Initializes system parameters
     * @param _registry address of Parachain Registry contract
     * @param _token address of token used for staking and rewards
     */
    constructor(
        address _registry,
        address _token
    ) Parachain(_registry) {
        require(_token != address(0), "must set token address");

        token = IERC20(_token);
        owner = msg.sender;
    }

    /**
     * @dev Allows the owner to initialize the governance (flex addy needed for governance deployment)
     * @param _governanceAddress address of governance contract (github.com/tellor-io/governance)
     */
    function init(address _governanceAddress) external {
        require(msg.sender == owner, "only owner can set governance address");
        require(governance == address(0), "governance address already set");
        require(
            _governanceAddress != address(0),
            "governance address can't be zero address"
        );
        governance = _governanceAddress;
    }

    /// @dev Called by the staker on the EVM compatible parachain that hosts the Tellor controller contracts.
    /// The staker will call this function and pass in the parachain account identifier, which is used to enable
    /// that account to report values over on the oracle consumer parachain.
    /// @param _paraId The parachain ID of the oracle consumer parachain.
    /// @param _account The account identifier of the reporter on the oracle consumer parachain.
    /// @param _amount The amount of tokens to stake.
    function depositParachainStake(uint32 _paraId, bytes calldata _account, uint256 _amount) external {
        require(governance != address(0), "governance address not set");

        // Ensure parachain is registered
        address parachainOwner = registry.owner(_paraId);
        require(parachainOwner != address(0x0), "parachain not registered");

        ParachainStakeInfo storage _parachainStakeInfo = parachainStakerDetails[_paraId][msg.sender];
        _parachainStakeInfo._account = _account;

        StakeInfo storage _staker = _parachainStakeInfo._stakeInfo;
        uint256 _stakedBalance = _staker.stakedBalance;
        uint256 _lockedBalance = _staker.lockedBalance;
        if (_lockedBalance > 0) {
            if (_lockedBalance >= _amount) {
                // if staker's locked balance covers full _amount, use that
                _staker.lockedBalance -= _amount;
                toWithdraw -= _amount;
            } else {
                // otherwise, stake the whole locked balance and transfer the
                // remaining amount from the staker's address
                require(
                    token.transferFrom(
                        msg.sender,
                        address(this),
                        _amount - _lockedBalance
                    )
                );
                toWithdraw -= _staker.lockedBalance;
                _staker.lockedBalance = 0;
            }
        } else {
            if (_stakedBalance == 0) {
                // if staked balance and locked balance equal 0, save current vote tally.
                // voting participation used for calculating rewards
                (bool _success, bytes memory _returnData) = governance.call(
                    abi.encodeWithSignature("getVoteCount()")
                );
                if (_success) {
                    _staker.startVoteCount = uint256(abi.decode(_returnData, (uint256)));
                }
                (_success,_returnData) = governance.call(
                    abi.encodeWithSignature("getVoteTallyByAddress(address)", msg.sender)
                );
                if(_success){
                    _staker.startVoteTally =  abi.decode(_returnData,(uint256));
                }
            }
            require(token.transferFrom(msg.sender, address(this), _amount));
        }
        _staker.startDate = block.timestamp; // This resets the staker start date to now
        emit NewStaker(msg.sender, _amount);
        emit NewParachainStaker(_paraId, msg.sender, _account, _amount);

        // Call XCM function to nofity consumer parachain of new staker
        reportStakeDeposited(_paraId, msg.sender, _account, _amount);
    }

    /// @dev Allows a staker on EVM compatible parachain to request withdrawal of their stake for 
    /// a specific oracle consumer parachain.
    /// @param _paraId The unique identifier of the oracle consumer parachain.
    /// @param _amount The amount of tokens to withdraw.
    function requestParachainStakeWithdraw(uint32 _paraId, uint256 _amount) external {
        // Ensure parachain is registered
        address parachainOwner = registry.owner(_paraId);
        require(parachainOwner != address(0x0), "parachain not registered");

        ParachainStakeInfo storage _parachainStakeInfo = parachainStakerDetails[_paraId][msg.sender]; 
        StakeInfo storage _staker = _parachainStakeInfo._stakeInfo;
        require(
            _staker.stakedBalance >= _amount,
            "insufficient staked balance"
        );
        _staker.startDate = block.timestamp;
        _staker.lockedBalance += _amount;
        toWithdraw += _amount;
        emit StakeWithdrawRequested(msg.sender, _amount);
        emit ParachainStakeWithdrawRequested(_paraId, _parachainStakeInfo._account, _amount);

        reportStakeWithdrawRequested(_paraId, _parachainStakeInfo._account, _amount);
    }

    /// @dev Called by oracle consumer parachain. Prevents staker from withdrawing stake until consumer
    /// parachain has confirmed that the account cannot report anymore.
    /// @param _paraId The unique identifier of the oracle consumer parachain.
    /// @param _staker The address of the staker requesting withdrawal.
    /// @param _amount The amount of tokens to withdraw.
    function confirmParachainStakeWithdrawRequest(uint32 _paraId, address _staker, uint256 _amount) external {
        address parachainOwner = registry.owner(_paraId);
        require(parachainOwner != address(0x0), "parachain not registered");
        require(msg.sender == registry.owner(_paraId), "not parachain owner");

        ParachainStakeInfo storage _parachainStakeInfo = parachainStakerDetails[_paraId][_staker];
        _parachainStakeInfo._lockedBalanceConfirmed = _amount;

        emit ParachainStakeWithdrawRequestConfirmed(_paraId, _staker, _amount);
    }

    /**
     * @dev Slashes a reporter and transfers their stake amount to the given recipient
     * Note: this function is only callable by the governance address.
     * @param _reporter is the address of the reporter being slashed
     * @param _recipient is the address receiving the reporter's stake
     * @return _slashAmount uint256 amount of token slashed and sent to recipient address
     */
    function slashParachainReporter(uint32 _paraId, address _reporter, address _recipient) external returns (uint256) {
        require(msg.sender == governance, "only governance can slash reporter");
        address parachainOwner = registry.owner(_paraId);
        require(parachainOwner != address(0x0), "parachain not registered");

        ParachainStakeInfo storage _parachainStakeInfo = parachainStakerDetails[_paraId][_reporter];
        StakeInfo storage _staker = _parachainStakeInfo._stakeInfo;
        uint256 _slashAmount = _staker.stakedBalance;
        require(token.transfer(_recipient, _slashAmount), "transfer failed");
        emit ParachainReporterSlashed(_paraId, _reporter, _recipient, _slashAmount);

        reportSlash(_paraId, _reporter, _recipient, _slashAmount);
        return _slashAmount;
    }


    /// @dev Allows a staker to withdraw their stake.
    /// @param _paraId Identifier of the oracle consumer parachain.
    function withdrawParachainStake(uint32 _paraId) external {
        address parachainOwner = registry.owner(_paraId);
        require(parachainOwner != address(0x0), "parachain not registered");

        ParachainStakeInfo storage _parachainStakeInfo = parachainStakerDetails[_paraId][msg.sender];
        StakeInfo storage _staker = _parachainStakeInfo._stakeInfo;
        require(
            block.timestamp - _staker.startDate >= 7 days,
            "lock period not expired"
        );
        require(
            _staker.lockedBalance > 0,
            "no locked balance to withdraw"
        );
        require(
            _staker.lockedBalance == _parachainStakeInfo._lockedBalanceConfirmed,
            "withdraw stake request not confirmed"
        );
        uint256 _amount = _staker.lockedBalance;
        require(token.transfer(msg.sender, _amount), "withdraw stake token transfer failed");
        toWithdraw -= _amount;
        _staker.lockedBalance = 0;
        _parachainStakeInfo._lockedBalanceConfirmed = 0;

        emit StakeWithdrawn(msg.sender);
        emit ParachainStakeWithdrawn(_paraId, msg.sender);

        reportStakeWithdrawn(_paraId, msg.sender, _parachainStakeInfo._account, _amount);
    }

    // *****************************************************************************
    // *                                                                           *
    // *                               Getters                                     *
    // *                                                                           *
    // *****************************************************************************

    /**
     * @dev Returns governance address
     * @return address governance
     */
    function getGovernanceAddress() external view returns (address) {
        return governance;
    }

    /**
     * @dev Returns the address of the token used for staking
     * @return address of the token used for staking
     */
    function getTokenAddress() external view returns (address) {
        return address(token);
    }

    /**
     * @dev Returns total amount of token staked for reporting
     * @return uint256 total amount of token staked
     */
    function getTotalStakeAmount() external view returns (uint256) {
        return totalStakeAmount;
    }

    /**
     * @dev Returns total number of current stakers. Reporters with stakedBalance less than stakeAmount are excluded from this total
     * @return uint256 total stakers
     */
    function getTotalStakers() external view returns (uint256) {
        return totalStakers;
    }

    /**
     * @dev Used during the upgrade process to verify valid Tellor contracts
     * @return bool value used to verify valid Tellor contracts
     */
    function verify() external pure returns (uint256) {
        return 9999;
    }

    // *****************************************************************************
    // *                                                                           *
    // *                          Internal functions                               *
    // *                                                                           *
    // *****************************************************************************


}