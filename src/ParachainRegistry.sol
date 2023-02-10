pragma solidity ^0.8.0;

// Various helper methods for interfacing with the Tellor pallet on another parachain via XCM
import "../lib/moonbeam/precompiles/XcmTransactorV2.sol";

    error NotAllowed();
    error NotOwner();
    error ParachainNotRegistered();

interface IRegistry {
    function owner(uint32 _paraId) external view returns(address);

    function palletIndex(uint32 _paraId) external view returns(bytes memory);

    function stakeAmount(uint32 _paraId) external view returns(uint256);
}

contract ParachainRegistry is IRegistry {
    address private contractOwner;
    address private stakingContract;

    mapping(uint32 => ParachainRegistration) private registrations;

    XcmTransactorV2 private constant xcmTransactor  = XCM_TRANSACTOR_V2_CONTRACT;

    modifier onlyOwner {
        if (msg.sender != contractOwner) revert NotOwner();
        _;
    }

    event ParachainRegistered(address caller, uint32 parachain, address owner);
    event StakingContractSet(address caller, address contractAddress);

    struct ParachainRegistration{
        address owner;
        bytes palletIndex;
        uint256 stakeAmount;
    }

    constructor () {
        contractOwner = msg.sender;
    }

    /// @dev Register parachain, along with index of Tellor pallet within corresponding runtime and stake amount.
    /// @param _paraId uint32 The parachain identifier.
    /// @param _owner address The multi-location derivative account, mapped from the Tellor pallet account on the parachain.
    /// @param _palletIndex uint8 The index of the Tellor pallet within the parachain's runtime.
    /// @param _stakeAmount uint256 The minimum stake amount for the parachain.
    function registerParachain(uint32 _paraId, address _owner, uint8 _palletIndex, uint256 _stakeAmount) external onlyOwner {
        ParachainRegistration memory registration;
        registration.owner = _owner;
        registration.palletIndex = abi.encodePacked(_palletIndex);
        registration.stakeAmount = _stakeAmount;
        registrations[_paraId] = registration;

        emit ParachainRegistered(msg.sender, _paraId, _owner);
    }

    function setStaking(address _address) external onlyOwner {
        stakingContract = _address;

        emit StakingContractSet(msg.sender, _address);
    }

    function owner(uint32 _paraId) public view returns(address) {
        return registrations[_paraId].owner;
    }

    function palletIndex(uint32 _paraId) external view returns(bytes memory) {
        return registrations[_paraId].palletIndex;
    }

    function stakeAmount(uint32 _paraId) external view returns(uint256) {
        return registrations[_paraId].stakeAmount;
    }

    /// @dev Report stake to a registered parachain.
    /// @param _paraId uint32 The parachain identifier.
    /// @param _staker address The address of the staker.
    /// @param _reporter bytes The corresponding address of the reporter on the parachain.
    /// @param _amount uint256 The staked amount for the parachain.
    function reportStake(uint32 _paraId, address _staker, bytes calldata _reporter, uint256 _amount) external {
        // Ensure sender is staking contract
        if (msg.sender != stakingContract) revert NotAllowed();
        if (owner(_paraId) == address(0x0)) revert ParachainNotRegistered();

        // Prepare remote call and send
        uint64 transactRequiredWeightAtMost = 5000000000;
        bytes memory call = reportStakeToParachain(_paraId, _staker, _reporter, _amount);
        uint256 feeAmount = 10000000000;
        uint64 overallWeight = 9000000000;
        transactThroughSigned(_paraId, transactRequiredWeightAtMost, call, feeAmount, overallWeight);
    }

    function transactThroughSigned(uint32 _paraId, uint64 _transactRequiredWeightAtMost, bytes memory _call, uint256 _feeAmount, uint64 _overallWeight) private {
        // Create multi-location based on supplied paraId
        XcmTransactorV2.Multilocation memory location;
        location.parents = 1;
        location.interior = new bytes[](1);
        location.interior[0] = parachain(_paraId);

        // Send remote transact
        xcmTransactor.transactThroughSignedMultilocation(location, location, _transactRequiredWeightAtMost, _call, _feeAmount, _overallWeight);
    }

    function reportStakeToParachain(uint32 _paraId, address _staker, bytes memory _reporter, uint256 _amount) private view returns(bytes memory) {
        // Encode call to report(staker, amount) within Tellor pallet
        return bytes.concat(registrations[_paraId].palletIndex, hex"00", bytes20(_staker), _reporter, bytes32(reverse(_amount)));
    }

    function parachain(uint32 _paraId) private pure returns (bytes memory) {
        // 0x00 denotes parachain: https://docs.moonbeam.network/builders/xcm/xcm-transactor/#building-the-precompile-multilocation
        return bytes.concat(hex"00", bytes4(_paraId));
    }

    // https://ethereum.stackexchange.com/questions/83626/how-to-reverse-byte-order-in-uint256-or-bytes32
    function reverse(uint256 input) internal pure returns (uint256 v) {
        v = input;

        // swap bytes
        v = ((v & 0xFF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00) >> 8) |
        ((v & 0x00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF) << 8);

        // swap 2-byte long pairs
        v = ((v & 0xFFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000) >> 16) |
        ((v & 0x0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF) << 16);

        // swap 4-byte long pairs
        v = ((v & 0xFFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000) >> 32) |
        ((v & 0x00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF) << 32);

        // swap 8-byte long pairs
        v = ((v & 0xFFFFFFFFFFFFFFFF0000000000000000FFFFFFFFFFFFFFFF0000000000000000) >> 64) |
        ((v & 0x0000000000000000FFFFFFFFFFFFFFFF0000000000000000FFFFFFFFFFFFFFFF) << 64);

        // swap 16-byte long pairs
        v = (v >> 128) | (v << 128);
    }
}