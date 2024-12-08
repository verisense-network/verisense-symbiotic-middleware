// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IRegistry} from "symbiotic/src/interfaces/common/IRegistry.sol";
import {IEntity} from "symbiotic/src/interfaces/common/IEntity.sol";
import {IVault} from "symbiotic/src/interfaces/vault/IVault.sol";
import {IBaseDelegator} from "symbiotic/src/interfaces/delegator/IBaseDelegator.sol";
import {IBaseSlasher} from "symbiotic/src/interfaces/slasher/IBaseSlasher.sol";
import {IOptInService} from "symbiotic/src/interfaces/service/IOptInService.sol";
import {IEntity} from "symbiotic/src/interfaces/common/IEntity.sol";
import {ISlasher} from "symbiotic/src/interfaces/slasher/ISlasher.sol";
import {IVetoSlasher} from "symbiotic/src/interfaces/slasher/IVetoSlasher.sol";
import {Subnetwork} from "symbiotic/src/contracts/libraries/Subnetwork.sol";
import {IDefaultOperatorRewards} from "symbiotic-rewards/src/interfaces/defaultOperatorRewards/IDefaultOperatorRewards.sol";
import {IDefaultStakerRewards} from "symbiotic-rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewards.sol";
import {KeyRegistry32} from "./KeyRegistry32.sol";
import {MapWithTimeData} from "./libraries/MapWithTimeData.sol";


contract VerisenseMiddleware is KeyRegistry32, Initializable, UUPSUpgradeable, OwnableUpgradeable {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using MapWithTimeData for EnumerableMap.AddressToUintMap;
    using Subnetwork for address;

    error NotOperator();
    error NotVault();

    error OperatorNotOptedIn();
    error OperatorNotRegistred();
    error OperarorGracePeriodNotPassed();
    error OperatorAlreadyRegistred();

    error VaultAlreadyRegistred();
    error VaultEpochTooShort();
    error VaultGracePeriodNotPassed();

    error InvalidSubnetworksCnt();

    error TooOldEpoch();
    error InvalidEpoch();

    error SlashingWindowTooShort();
    error TooBigSlashAmount();
    error UnknownSlasherType();

    struct ValidatorData {
        address operator;
        uint256 stake;
        bytes32 key;
    }

    address public  NETWORK;
    address public  OPERATOR_REGISTRY;
    address public  VAULT_FACTORY;
    address public  OPERATOR_NET_OPTIN;
    address public  OWNER;
    uint48 public  EPOCH_DURATION;
    uint48 public  SLASHING_WINDOW;
    uint48 public  START_TIME;

    uint48 private constant INSTANT_SLASHER_TYPE = 0;
    uint48 private constant VETO_SLASHER_TYPE = 1;

    uint256 public subnetworksCnt;
    mapping(uint48 => uint256) public totalStakeCache;
    mapping(uint48 => bool) public totalStakeCached;
    mapping(uint48 => mapping(address => uint256)) public operatorStakeCache;
    EnumerableMap.AddressToUintMap private operators;
    EnumerableMap.AddressToUintMap private vaults;

    address public  REWARD_ERC20_TOKEN;
    address public  OPERATOR_REWARD_CONTRACT;
    address public  STAKER_REWARD_CONTRACT;

    modifier updateStakeCache(uint48 epoch) {
        if (!totalStakeCached[epoch]) {
            calcAndCacheStakes(epoch);
        }
        _;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    function initialize(
        address _network,
        address _operatorRegistry,
        address _vaultFactory,
        address _operatorNetOptin,
        uint48 _epochDuration,
        uint48 _slashingWindow
    ) public initializer {
        if (_slashingWindow < _epochDuration) {
            revert SlashingWindowTooShort();
        }
        START_TIME = Time.timestamp();
        EPOCH_DURATION = _epochDuration;
        NETWORK = _network;
        OPERATOR_REGISTRY = _operatorRegistry;
        VAULT_FACTORY = _vaultFactory;
        OPERATOR_NET_OPTIN = _operatorNetOptin;
        SLASHING_WINDOW = _slashingWindow;
        subnetworksCnt = 1;
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    function getEpochStartTs(uint48 epoch) public view returns (uint48 timestamp) {
        return START_TIME + epoch * EPOCH_DURATION;
    }

    function getEpochAtTs(uint48 timestamp) public view returns (uint48 epoch) {
        return (timestamp - START_TIME) / EPOCH_DURATION;
    }

    function getCurrentEpoch() public view returns (uint48 epoch) {
        return getEpochAtTs(Time.timestamp());
    }

    function registerOperator(address operator, bytes32 key) external onlyOwner {
        if (operators.contains(operator)) {
            revert OperatorAlreadyRegistred();
        }

        if (!IRegistry(OPERATOR_REGISTRY).isEntity(operator)) {
            revert NotOperator();
        }

        if (!IOptInService(OPERATOR_NET_OPTIN).isOptedIn(operator, NETWORK)) {
            revert OperatorNotOptedIn();
        }

        updateKey(operator, key);

        operators.add(operator);
        operators.enable(operator);
    }

    function updateOperatorKey(address operator, bytes32 key) external onlyOwner {
        if (!operators.contains(operator)) {
            revert OperatorNotRegistred();
        }
        updateKey(operator, key);
    }

    function pauseOperator(address operator) external onlyOwner {
        operators.disable(operator);
    }

    function unpauseOperator(address operator) external onlyOwner {
        operators.enable(operator);
    }

    function unregisterOperator(address operator) external onlyOwner {
        (, uint48 disabledTime) = operators.getTimes(operator);

        if (disabledTime == 0 || disabledTime + SLASHING_WINDOW > Time.timestamp()) {
            revert OperarorGracePeriodNotPassed();
        }

        operators.remove(operator);
    }

    function registerVault(address vault) external onlyOwner {
        if (vaults.contains(vault)) {
            revert VaultAlreadyRegistred();
        }

        if (!IRegistry(VAULT_FACTORY).isEntity(vault)) {
            revert NotVault();
        }

        uint48 vaultEpoch = IVault(vault).epochDuration();

        address slasher = IVault(vault).slasher();
        if (slasher != address(0) && IEntity(slasher).TYPE() == VETO_SLASHER_TYPE) {
            vaultEpoch -= IVetoSlasher(slasher).vetoDuration();
        }

        if (vaultEpoch < SLASHING_WINDOW) {
            revert VaultEpochTooShort();
        }

        vaults.add(vault);
        vaults.enable(vault);
    }

    function pauseVault(address vault) external onlyOwner {
        vaults.disable(vault);
    }

    function unpauseVault(address vault) external onlyOwner {
        vaults.enable(vault);
    }

    function unregisterVault(address vault) external onlyOwner {
        (, uint48 disabledTime) = vaults.getTimes(vault);

        if (disabledTime == 0 || disabledTime + SLASHING_WINDOW > Time.timestamp()) {
            revert VaultGracePeriodNotPassed();
        }

        vaults.remove(vault);
    }

    function setSubnetworksCnt(uint256 _subnetworksCnt) external onlyOwner {
        if (subnetworksCnt >= _subnetworksCnt) {
            revert InvalidSubnetworksCnt();
        }

        subnetworksCnt = _subnetworksCnt;
    }

    function getOperatorStake(address operator, uint48 epoch) public view returns (uint256 stake) {
        if (totalStakeCached[epoch]) {
            return operatorStakeCache[epoch][operator];
        }

        uint48 epochStartTs = getEpochStartTs(epoch);

        for (uint256 i; i < vaults.length(); ++i) {
            (address vault, uint48 enabledTime, uint48 disabledTime) = vaults.atWithTimes(i);

            // just skip the vault if it was enabled after the target epoch or not enabled
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            for (uint96 j = 0; j < subnetworksCnt; ++j) {
                stake += IBaseDelegator(IVault(vault).delegator()).stakeAt(
                    NETWORK.subnetwork(j), operator, epochStartTs, new bytes(0)
                );
            }
        }

        return stake;
    }

    function getTotalStake(uint48 epoch) public view returns (uint256) {
        if (totalStakeCached[epoch]) {
            return totalStakeCache[epoch];
        }
        return _calcTotalStake(epoch);
    }

    function getValidatorSet() public view returns (ValidatorData[] memory validatorsData) {
        uint48 epoch = getCurrentEpoch();
        uint48 epochStartTs = getEpochStartTs(epoch);

        validatorsData = new ValidatorData[](operators.length());
        uint256 valIdx = 0;

        for (uint256 i; i < operators.length(); ++i) {
            (address operator, uint48 enabledTime, uint48 disabledTime) = operators.atWithTimes(i);

            // just skip operator if it was added after the target epoch or paused
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            bytes32 key = getOperatorKeyAt(operator, epochStartTs);
            if (key == bytes32(0)) {
                continue;
            }

            uint256 stake = getOperatorStake(operator, epoch);

            validatorsData[valIdx++] = ValidatorData(operator, stake, key);
        }

        // shrink array to skip unused slots
        /// @solidity memory-safe-assembly
        assembly {
            mstore(validatorsData, valIdx)
        }
    }

    // just for example, our devnets don't support slashing
    function slash(uint48 epoch, address operator, uint256 amount) public onlyOwner updateStakeCache(epoch) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        if (epochStartTs < Time.timestamp() - SLASHING_WINDOW) {
            revert TooOldEpoch();
        }

        uint256 totalOperatorStake = getOperatorStake(operator, epoch);

        if (totalOperatorStake < amount) {
            revert TooBigSlashAmount();
        }

        // simple pro-rata slasher
        for (uint256 i; i < vaults.length(); ++i) {
            (address vault, uint48 enabledTime, uint48 disabledTime) = operators.atWithTimes(i);

            // just skip the vault if it was enabled after the target epoch or not enabled
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            for (uint96 j = 0; j < subnetworksCnt; ++j) {
                bytes32 subnetwork = NETWORK.subnetwork(j);
                uint256 vaultStake =
                    IBaseDelegator(IVault(vault).delegator()).stakeAt(subnetwork, operator, epochStartTs, new bytes(0));
                _slashVault(epochStartTs, vault, subnetwork, operator, amount * vaultStake / totalOperatorStake);
            }
        }
    }

    function calcAndCacheStakes(uint48 epoch) public returns (uint256 totalStake) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        // for epoch older than SLASHING_WINDOW total stake can be invalidated (use cache)
        if (epochStartTs < Time.timestamp() - SLASHING_WINDOW) {
            revert TooOldEpoch();
        }

        if (epochStartTs > Time.timestamp()) {
            revert InvalidEpoch();
        }

        for (uint256 i; i < operators.length(); ++i) {
            (address operator, uint48 enabledTime, uint48 disabledTime) = operators.atWithTimes(i);

            // just skip operator if it was added after the target epoch or paused
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            uint256 operatorStake = getOperatorStake(operator, epoch);
            operatorStakeCache[epoch][operator] = operatorStake;

            totalStake += operatorStake;
        }

        totalStakeCached[epoch] = true;
        totalStakeCache[epoch] = totalStake;
    }

    function _calcTotalStake(uint48 epoch) private view returns (uint256 totalStake) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        // for epoch older than SLASHING_WINDOW total stake can be invalidated (use cache)
        if (epochStartTs < Time.timestamp() - SLASHING_WINDOW) {
            revert TooOldEpoch();
        }

        if (epochStartTs > Time.timestamp()) {
            revert InvalidEpoch();
        }

        for (uint256 i; i < operators.length(); ++i) {
            (address operator, uint48 enabledTime, uint48 disabledTime) = operators.atWithTimes(i);

            // just skip operator if it was added after the target epoch or paused
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            uint256 operatorStake = getOperatorStake(operator, epoch);
            totalStake += operatorStake;
        }
    }

    function _wasActiveAt(uint48 enabledTime, uint48 disabledTime, uint48 timestamp) private pure returns (bool) {
        return enabledTime != 0 && enabledTime <= timestamp && (disabledTime == 0 || disabledTime >= timestamp);
    }

    function _slashVault(
        uint48 timestamp,
        address vault,
        bytes32 subnetwork,
        address operator,
        uint256 amount
    ) private {
        address slasher = IVault(vault).slasher();
        uint256 slasherType = IEntity(slasher).TYPE();
        if (slasherType == INSTANT_SLASHER_TYPE) {
            ISlasher(slasher).slash(subnetwork, operator, amount, timestamp, new bytes(0));
        } else if (slasherType == VETO_SLASHER_TYPE) {
            IVetoSlasher(slasher).requestSlash(subnetwork, operator, amount, timestamp, new bytes(0));
        } else {
            revert UnknownSlasherType();
        }
    }

    function set_reward_information(address token, address operatorRewards, address stakerRewards) external onlyOwner {
        REWARD_ERC20_TOKEN = token;
        OPERATOR_REWARD_CONTRACT = operatorRewards;
        STAKER_REWARD_CONTRACT = stakerRewards;
    }

    function rewardOperators(
        uint256 amount,
        bytes32 root
    ) external onlyOwner {
        IDefaultOperatorRewards(OPERATOR_REWARD_CONTRACT).distributeRewards(NETWORK, REWARD_ERC20_TOKEN, amount, root);
    }

    function rewardStakers(
        address token,
        uint256 amount
    ) external onlyOwner {
        IDefaultStakerRewards(STAKER_REWARD_CONTRACT).distributeRewards(NETWORK, token, amount, bytes(""));
    }

    using SafeERC20 for IERC20;

    bytes32 public root;

    uint256 public balance;

    mapping(address account => uint256 amount) public claimed;

    function _distributeRewards(uint256 amount, bytes32 root_) internal  {
        if (amount > 0) {
            uint256 balanceBefore = IERC20(REWARD_ERC20_TOKEN).balanceOf(address(this));
            IERC20(REWARD_ERC20_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
            amount = IERC20(REWARD_ERC20_TOKEN).balanceOf(address(this)) - balanceBefore;

            if (amount == 0) {
                revert InsufficientTransfer();
            }

            balance += amount;
        }
        root = root_;
    }

    function claimRewards(
        address recipient,
        uint256 totalClaimable,
        bytes32[] calldata proof
    ) external returns (uint256 amount) {
        bytes32 root_ = root;
        if (root_ == bytes32(0)) {
            revert RootNotSet();
        }
        if (
            !MerkleProof.verifyCalldata(
            proof, root_, keccak256(bytes.concat(keccak256(abi.encode(msg.sender, "symbiotic", totalClaimable))))
        )
        ) {
            revert InvalidProof();
        }

        uint256 claimed_ = claimed[msg.sender];
        if (totalClaimable <= claimed_) {
            revert InsufficientTotalClaimable();
        }

        amount = totalClaimable - claimed_;

        if (amount > balance) {
            revert InsufficientBalance();
        }

        balance = balance - amount;

        claimed[msg.sender] = totalClaimable;
        IERC20(REWARD_ERC20_TOKEN).safeTransfer(recipient, amount);
    }

    error InsufficientBalance();
    error InsufficientTotalClaimable();
    error InsufficientTransfer();
    error InvalidProof();
    error NotNetworkMiddleware();
    error RootNotSet();
}
