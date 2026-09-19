// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract RobinhoodStakingFarm is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant MAX_TIERS = uint256(type(uint8).max) + 1;
    /// @dev 970 basis points = 9.70%.
    uint256 public constant EARLY_WITHDRAWAL_FEE_BPS = 970;
    uint256 private constant ACC_PRECISION = 1e24;

    struct PoolInfo {
        address lpToken;
        address rewardToken;
        address bonusToken;
        uint256 rewardPerSecond;
        uint256 unaccruedRewardBalance;
        uint256 bonusBalance;
        uint256 totalStaked;
        uint64 lastRewardTime;
        bool paused;
        bool allowDuplicateLp;
    }

    struct TierInfo {
        uint64 lockDuration;
        uint32 rewardMultiplierBps;
        uint256 totalStaked;
        uint256 accRewardPerShare;
        uint256 accBonusPerShare;
        bool hasDeposits;
        bool enabled;
    }

    struct PositionInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 bonusDebt;
        uint64 depositedAt;
        uint64 unlockAt;
        uint8 tierId;
        bool closed;
    }

    struct PendingRewards {
        uint256 rewardAmount;
        uint256 bonusAmount;
    }

    PoolInfo[] private _pools;
    mapping(uint256 => TierInfo[]) private _poolTiers;
    mapping(uint256 => mapping(address => PositionInfo[])) private _positions;
    mapping(address => uint256) public lpPoolCount;
    mapping(address => bool) public lpDuplicatePolicyInitialized;
    mapping(address => bool) public lpAllowsDuplicates;

    address public adminWallet;

    event AdminWalletUpdated(address indexed previousAdminWallet, address indexed newAdminWallet);
    event PoolAdded(
        uint256 indexed poolId,
        address indexed lpToken,
        address indexed rewardToken,
        address bonusToken,
        uint256 rewardPerSecond,
        bool allowDuplicateLp
    );
    event PoolRewardRateUpdated(uint256 indexed poolId, uint256 previousRewardPerSecond, uint256 newRewardPerSecond);
    event PoolRewardTokenUpdated(uint256 indexed poolId, address indexed previousRewardToken, address indexed newRewardToken);
    event PoolBonusTokenUpdated(uint256 indexed poolId, address indexed previousBonusToken, address indexed newBonusToken);
    event PoolPaused(uint256 indexed poolId, bool isPaused);
    event TierConfigUpdated(
        uint256 indexed poolId,
        uint256 indexed tierId,
        uint64 lockDuration,
        uint32 rewardMultiplierBps,
        bool enabled
    );
    event RewardsFunded(uint256 indexed poolId, address indexed rewardToken, uint256 amount, uint256 newUnaccruedRewardBalance);
    event BonusDistributed(uint256 indexed poolId, address indexed bonusToken, uint256 amount);
    event Deposited(address indexed user, uint256 indexed poolId, uint256 indexed positionId, uint256 tierId, uint256 amount, uint64 unlockAt);
    event RewardsClaimed(address indexed user, uint256 indexed poolId, uint256 indexed positionId, uint256 rewardAmount, uint256 bonusAmount);
    event Withdrawn(
        address indexed user,
        uint256 indexed poolId,
        uint256 indexed positionId,
        uint256 amount,
        uint256 netAmount,
        uint256 earlyWithdrawalFee
    );

    constructor(address initialOwner, address initialAdminWallet) Ownable(initialOwner) {
        require(initialOwner != address(0), "owner is zero");
        _setAdminWallet(initialAdminWallet);
    }

    modifier validPool(uint256 poolId) {
        require(poolId < _pools.length, "pool not found");
        _;
    }

    modifier validTier(uint256 poolId, uint256 tierId) {
        require(tierId < _poolTiers[poolId].length, "tier not found");
        _;
    }

    function poolCount() external view returns (uint256) {
        return _pools.length;
    }

    function tierCount(uint256 poolId) external view validPool(poolId) returns (uint256) {
        return _poolTiers[poolId].length;
    }

    function getPool(uint256 poolId) external view validPool(poolId) returns (PoolInfo memory) {
        return _pools[poolId];
    }

    function getTier(uint256 poolId, uint256 tierId) external view validPool(poolId) validTier(poolId, tierId) returns (TierInfo memory) {
        return _poolTiers[poolId][tierId];
    }

    function getPosition(uint256 poolId, address user, uint256 positionId)
        external
        view
        validPool(poolId)
        returns (PositionInfo memory)
    {
        // positionId is the append-order index within a user's positions for a pool, not the tier id.
        require(positionId < _positions[poolId][user].length, "position not found");
        return _positions[poolId][user][positionId];
    }

    function positionsLength(uint256 poolId, address user) external view validPool(poolId) returns (uint256) {
        return _positions[poolId][user].length;
    }

    function addPool(
        address lpToken,
        address rewardToken,
        address bonusToken,
        uint256 rewardPerSecond,
        uint64[] calldata lockDurations,
        uint32[] calldata rewardMultipliersBps,
        bool allowDuplicateLp
    ) external onlyOwner {
        require(lpToken != address(0), "lp token is zero");
        require(rewardToken != address(0), "reward token is zero");
        require(bonusToken != address(0), "bonus token is zero");
        require(lockDurations.length == rewardMultipliersBps.length, "tier length mismatch");
        require(lockDurations.length > 0, "no tiers");
        require(lockDurations.length <= MAX_TIERS, "too many tiers");
        if (!lpDuplicatePolicyInitialized[lpToken]) {
            lpDuplicatePolicyInitialized[lpToken] = true;
            lpAllowsDuplicates[lpToken] = allowDuplicateLp;
        } else {
            require(lpAllowsDuplicates[lpToken], "duplicate lp pool");
            require(allowDuplicateLp, "duplicate lp requires opt-in");
        }

        uint256 poolId = _pools.length;
        _pools.push(
            PoolInfo({
                lpToken: lpToken,
                rewardToken: rewardToken,
                bonusToken: bonusToken,
                rewardPerSecond: rewardPerSecond,
                unaccruedRewardBalance: 0,
                bonusBalance: 0,
                totalStaked: 0,
                lastRewardTime: uint64(block.timestamp),
                paused: false,
                allowDuplicateLp: allowDuplicateLp
            })
        );

        for (uint256 i = 0; i < lockDurations.length; i++) {
            require(rewardMultipliersBps[i] > 0, "multiplier is zero");
            _poolTiers[poolId].push(
                TierInfo({
                    lockDuration: lockDurations[i],
                    rewardMultiplierBps: rewardMultipliersBps[i],
                    totalStaked: 0,
                    accRewardPerShare: 0,
                    accBonusPerShare: 0,
                    hasDeposits: false,
                    enabled: true
                })
            );
        }

        lpPoolCount[lpToken] += 1;
        emit PoolAdded(poolId, lpToken, rewardToken, bonusToken, rewardPerSecond, allowDuplicateLp);
    }

    function setAdminWallet(address newAdminWallet) external onlyOwner {
        _setAdminWallet(newAdminWallet);
    }

    function setPoolRewardPerSecond(uint256 poolId, uint256 newRewardPerSecond) external onlyOwner validPool(poolId) {
        _updatePool(poolId);
        uint256 previousRewardPerSecond = _pools[poolId].rewardPerSecond;
        _pools[poolId].rewardPerSecond = newRewardPerSecond;
        emit PoolRewardRateUpdated(poolId, previousRewardPerSecond, newRewardPerSecond);
    }

    function setPoolRewardToken(uint256 poolId, address newRewardToken) external onlyOwner validPool(poolId) {
        require(newRewardToken != address(0), "reward token is zero");
        _updatePool(poolId);
        PoolInfo storage pool = _pools[poolId];
        require(pool.totalStaked == 0, "active stake exists");
        require(pool.unaccruedRewardBalance == 0, "reward balance exists");
        address previousRewardToken = pool.rewardToken;
        pool.rewardToken = newRewardToken;
        emit PoolRewardTokenUpdated(poolId, previousRewardToken, newRewardToken);
    }

    function setPoolPaused(uint256 poolId, bool isPaused) external onlyOwner validPool(poolId) {
        _pools[poolId].paused = isPaused;
        emit PoolPaused(poolId, isPaused);
    }

    function setPoolBonusToken(uint256 poolId, address newBonusToken) external onlyOwner validPool(poolId) {
        require(newBonusToken != address(0), "bonus token is zero");
        _updatePool(poolId);
        PoolInfo storage pool = _pools[poolId];
        require(pool.totalStaked == 0, "active stake exists");
        require(pool.bonusBalance == 0, "bonus balance exists");
        address previousBonusToken = pool.bonusToken;
        pool.bonusToken = newBonusToken;
        emit PoolBonusTokenUpdated(poolId, previousBonusToken, newBonusToken);
    }

    function setTierConfig(
        uint256 poolId,
        uint256 tierId,
        uint64 lockDuration,
        uint32 rewardMultiplierBps,
        bool enabled
    ) external onlyOwner validPool(poolId) validTier(poolId, tierId) {
        require(rewardMultiplierBps > 0, "multiplier is zero");
        _updatePool(poolId);
        TierInfo storage tier = _poolTiers[poolId][tierId];
        require(!tier.hasDeposits || lockDuration == tier.lockDuration, "lock duration immutable");
        tier.lockDuration = lockDuration;
        tier.rewardMultiplierBps = rewardMultiplierBps;
        tier.enabled = enabled;
        emit TierConfigUpdated(poolId, tierId, lockDuration, rewardMultiplierBps, enabled);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function fundRewards(uint256 poolId, uint256 amount) external onlyOwner validPool(poolId) whenNotPaused {
        require(amount > 0, "amount is zero");
        _updatePool(poolId);

        PoolInfo storage pool = _pools[poolId];
        IERC20(pool.rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        pool.unaccruedRewardBalance += amount;

        emit RewardsFunded(poolId, pool.rewardToken, amount, pool.unaccruedRewardBalance);
    }

    function distributeBonusRewards(uint256 poolId, uint256 amount) external onlyOwner validPool(poolId) whenNotPaused {
        require(amount > 0, "amount is zero");
        _updatePool(poolId);

        PoolInfo storage pool = _pools[poolId];
        require(pool.totalStaked > 0, "no stakers");
        IERC20(pool.bonusToken).safeTransferFrom(msg.sender, address(this), amount);
        pool.bonusBalance += amount;

        TierInfo[] storage tiers = _poolTiers[poolId];
        uint256 remaining = amount;
        uint256 lastActiveTier = type(uint256).max;
        for (uint256 i = 0; i < tiers.length; i++) {
            if (tiers[i].totalStaked > 0) {
                lastActiveTier = i;
            }
        }

        for (uint256 i = 0; i < tiers.length; i++) {
            TierInfo storage tier = tiers[i];
            if (tier.totalStaked == 0) {
                continue;
            }

            uint256 tierAmount = i == lastActiveTier
                ? remaining
                : Math.mulDiv(amount, tier.totalStaked, pool.totalStaked);
            remaining -= tierAmount;
            tier.accBonusPerShare += Math.mulDiv(tierAmount, ACC_PRECISION, tier.totalStaked);
        }

        emit BonusDistributed(poolId, pool.bonusToken, amount);
    }

    function deposit(uint256 poolId, uint256 tierId, uint256 amount)
        external
        nonReentrant
        validPool(poolId)
        validTier(poolId, tierId)
        whenNotPaused
    {
        require(amount > 0, "amount is zero");

        PoolInfo storage pool = _pools[poolId];
        require(!pool.paused, "pool is paused");

        _updatePool(poolId);

        TierInfo storage tier = _poolTiers[poolId][tierId];
        require(tier.enabled, "tier disabled");

        IERC20(pool.lpToken).safeTransferFrom(msg.sender, address(this), amount);

        PositionInfo[] storage userPositions = _positions[poolId][msg.sender];
        uint256 positionId = userPositions.length;
        uint256 unlockAtValue = block.timestamp + tier.lockDuration;
        require(unlockAtValue <= type(uint64).max, "unlock overflow");
        uint64 unlockAt = uint64(unlockAtValue);
        userPositions.push(
            PositionInfo({
                amount: amount,
                rewardDebt: Math.mulDiv(amount, tier.accRewardPerShare, ACC_PRECISION),
                bonusDebt: Math.mulDiv(amount, tier.accBonusPerShare, ACC_PRECISION),
                depositedAt: uint64(block.timestamp),
                unlockAt: unlockAt,
                tierId: uint8(tierId),
                closed: false
            })
        );

        tier.hasDeposits = true;
        tier.totalStaked += amount;
        pool.totalStaked += amount;

        emit Deposited(msg.sender, poolId, positionId, tierId, amount, unlockAt);
    }

    function claim(uint256 poolId, uint256 positionId) external nonReentrant validPool(poolId) whenNotPaused {
        _updatePool(poolId);
        _claimPosition(poolId, msg.sender, positionId);
    }

    function claimMany(uint256 poolId, uint256[] calldata positionIds) external nonReentrant validPool(poolId) whenNotPaused {
        _updatePool(poolId);
        for (uint256 i = 0; i < positionIds.length; i++) {
            _claimPosition(poolId, msg.sender, positionIds[i]);
        }
    }

    function withdraw(uint256 poolId, uint256 positionId, uint256 amount) external nonReentrant validPool(poolId) {
        require(amount > 0, "amount is zero");
        _updatePool(poolId);

        PositionInfo storage position = _getPosition(poolId, msg.sender, positionId);
        require(!position.closed, "position closed");
        require(position.amount >= amount, "insufficient position");

        PoolInfo storage pool = _pools[poolId];
        TierInfo storage tier = _poolTiers[poolId][position.tierId];

        PendingRewards memory pending = _pendingForPosition(position, tier);

        uint256 remainingAmount = position.amount - amount;
        position.amount = remainingAmount;
        position.rewardDebt = Math.mulDiv(remainingAmount, tier.accRewardPerShare, ACC_PRECISION);
        position.bonusDebt = Math.mulDiv(remainingAmount, tier.accBonusPerShare, ACC_PRECISION);
        if (remainingAmount == 0) {
            position.closed = true;
        }

        tier.totalStaked -= amount;
        pool.totalStaked -= amount;

        uint256 earlyWithdrawalFee = 0;
        if (tier.lockDuration > 0 && block.timestamp < position.unlockAt) {
            earlyWithdrawalFee = Math.mulDiv(amount, EARLY_WITHDRAWAL_FEE_BPS, BASIS_POINTS);
        }
        uint256 netAmount = amount - earlyWithdrawalFee;

        _payoutRewards(pool, msg.sender, poolId, positionId, pending);
        if (earlyWithdrawalFee > 0) {
            IERC20(pool.lpToken).safeTransfer(adminWallet, earlyWithdrawalFee);
        }
        IERC20(pool.lpToken).safeTransfer(msg.sender, netAmount);

        emit Withdrawn(msg.sender, poolId, positionId, amount, netAmount, earlyWithdrawalFee);
    }

    function pendingRewards(uint256 poolId, address user, uint256 positionId)
        external
        view
        validPool(poolId)
        returns (PendingRewards memory)
    {
        require(positionId < _positions[poolId][user].length, "position not found");
        PositionInfo memory position = _positions[poolId][user][positionId];
        if (position.closed || position.amount == 0) {
            return PendingRewards({rewardAmount: 0, bonusAmount: 0});
        }

        TierInfo memory tier = _poolTiers[poolId][position.tierId];
        uint256 accRewardPerShare = _previewAccRewardPerShare(poolId, position.tierId);
        uint256 rewardAmount = Math.mulDiv(position.amount, accRewardPerShare, ACC_PRECISION) - position.rewardDebt;
        uint256 bonusAmount = Math.mulDiv(position.amount, tier.accBonusPerShare, ACC_PRECISION) - position.bonusDebt;
        return PendingRewards({rewardAmount: rewardAmount, bonusAmount: bonusAmount});
    }

    function _claimPosition(uint256 poolId, address user, uint256 positionId) internal {
        PositionInfo storage position = _getPosition(poolId, user, positionId);
        require(!position.closed, "position closed");

        TierInfo storage tier = _poolTiers[poolId][position.tierId];
        PendingRewards memory pending = _pendingForPosition(position, tier);

        position.rewardDebt = Math.mulDiv(position.amount, tier.accRewardPerShare, ACC_PRECISION);
        position.bonusDebt = Math.mulDiv(position.amount, tier.accBonusPerShare, ACC_PRECISION);

        _payoutRewards(_pools[poolId], user, poolId, positionId, pending);
    }

    function _payoutRewards(
        PoolInfo storage pool,
        address user,
        uint256 poolId,
        uint256 positionId,
        PendingRewards memory pending
    ) internal {
        if (pending.rewardAmount > 0) {
            IERC20(pool.rewardToken).safeTransfer(user, pending.rewardAmount);
        }
        if (pending.bonusAmount > 0) {
            pool.bonusBalance -= pending.bonusAmount;
            IERC20(pool.bonusToken).safeTransfer(user, pending.bonusAmount);
        }
        emit RewardsClaimed(user, poolId, positionId, pending.rewardAmount, pending.bonusAmount);
    }

    function _getPosition(uint256 poolId, address user, uint256 positionId)
        internal
        view
        returns (PositionInfo storage position)
    {
        require(positionId < _positions[poolId][user].length, "position not found");
        position = _positions[poolId][user][positionId];
    }

    function _pendingForPosition(PositionInfo storage position, TierInfo storage tier)
        internal
        view
        returns (PendingRewards memory)
    {
        if (position.amount == 0) {
            return PendingRewards({rewardAmount: 0, bonusAmount: 0});
        }

        uint256 rewardAmount = Math.mulDiv(position.amount, tier.accRewardPerShare, ACC_PRECISION) - position.rewardDebt;
        uint256 bonusAmount = Math.mulDiv(position.amount, tier.accBonusPerShare, ACC_PRECISION) - position.bonusDebt;
        return PendingRewards({rewardAmount: rewardAmount, bonusAmount: bonusAmount});
    }

    function _previewAccRewardPerShare(uint256 poolId, uint256 tierId) internal view returns (uint256) {
        PoolInfo memory pool = _pools[poolId];
        TierInfo[] storage tiers = _poolTiers[poolId];
        TierInfo memory targetTier = tiers[tierId];

        if (block.timestamp <= pool.lastRewardTime || pool.unaccruedRewardBalance == 0 || pool.rewardPerSecond == 0) {
            return targetTier.accRewardPerShare;
        }

        uint256 elapsed = block.timestamp - pool.lastRewardTime;
        uint256[] memory idealRewards = new uint256[](tiers.length);
        uint256 totalIdeal;
        uint256 lastActiveTier = type(uint256).max;

        for (uint256 i = 0; i < tiers.length; i++) {
            TierInfo memory tier = tiers[i];
            if (!tier.enabled || tier.totalStaked == 0 || tier.rewardMultiplierBps == 0) {
                continue;
            }

            uint256 idealReward = Math.mulDiv(
                Math.mulDiv(elapsed, pool.rewardPerSecond, 1),
                tier.rewardMultiplierBps,
                BASIS_POINTS
            );
            if (idealReward == 0) {
                continue;
            }

            idealRewards[i] = idealReward;
            totalIdeal += idealReward;
            lastActiveTier = i;
        }

        if (totalIdeal == 0 || idealRewards[tierId] == 0 || targetTier.totalStaked == 0) {
            return targetTier.accRewardPerShare;
        }

        uint256 distributable = Math.min(totalIdeal, pool.unaccruedRewardBalance);
        uint256 tierReward = tierId == lastActiveTier
            ? distributable - _distributedBeforeTier(tierId, idealRewards, distributable, totalIdeal)
            : Math.mulDiv(distributable, idealRewards[tierId], totalIdeal);

        return targetTier.accRewardPerShare + Math.mulDiv(tierReward, ACC_PRECISION, targetTier.totalStaked);
    }

    function _distributedBeforeTier(
        uint256 tierId,
        uint256[] memory idealRewards,
        uint256 distributable,
        uint256 totalIdeal
    ) internal pure returns (uint256 distributed) {
        for (uint256 i = 0; i < tierId; i++) {
            if (idealRewards[i] > 0) {
                distributed += Math.mulDiv(distributable, idealRewards[i], totalIdeal);
            }
        }
    }

    function _updatePool(uint256 poolId) internal {
        PoolInfo storage pool = _pools[poolId];
        uint256 currentTime = block.timestamp;
        if (currentTime <= pool.lastRewardTime) {
            return;
        }

        uint256 elapsed = currentTime - pool.lastRewardTime;
        pool.lastRewardTime = uint64(currentTime);

        if (pool.unaccruedRewardBalance == 0 || pool.rewardPerSecond == 0) {
            return;
        }

        TierInfo[] storage tiers = _poolTiers[poolId];
        uint256[] memory idealRewards = new uint256[](tiers.length);
        uint256 totalIdeal;
        uint256 lastActiveTier = type(uint256).max;

        for (uint256 i = 0; i < tiers.length; i++) {
            TierInfo storage tier = tiers[i];
            if (!tier.enabled || tier.totalStaked == 0 || tier.rewardMultiplierBps == 0) {
                continue;
            }

            uint256 idealReward = Math.mulDiv(
                Math.mulDiv(elapsed, pool.rewardPerSecond, 1),
                tier.rewardMultiplierBps,
                BASIS_POINTS
            );
            if (idealReward == 0) {
                continue;
            }

            idealRewards[i] = idealReward;
            totalIdeal += idealReward;
            lastActiveTier = i;
        }

        if (totalIdeal == 0) {
            return;
        }

        uint256 distributable = Math.min(totalIdeal, pool.unaccruedRewardBalance);
        pool.unaccruedRewardBalance -= distributable;
        uint256 remaining = distributable;

        for (uint256 i = 0; i < tiers.length; i++) {
            TierInfo storage tier = tiers[i];
            uint256 idealReward = idealRewards[i];
            if (idealReward == 0) {
                continue;
            }

            uint256 tierReward = i == lastActiveTier ? remaining : Math.mulDiv(distributable, idealReward, totalIdeal);
            remaining -= tierReward;
            tier.accRewardPerShare += Math.mulDiv(tierReward, ACC_PRECISION, tier.totalStaked);
        }
    }

    function _setAdminWallet(address newAdminWallet) internal {
        require(newAdminWallet != address(0), "admin wallet is zero");
        address previousAdminWallet = adminWallet;
        adminWallet = newAdminWallet;
        emit AdminWalletUpdated(previousAdminWallet, newAdminWallet);
    }
}
