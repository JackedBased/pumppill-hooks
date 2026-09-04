// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// @title DripVault ("Dev-Drip")
/// @notice Escrow for a creator's token allocation with a pool-aware,
///         rate-limited release. Per 24h epoch the vault releases at most
///         min(dripBips of allocation, depthBips of current in-range pool
///         depth). Releases go only to the immutable devRecipient.
///
///         No owner, no admin, no upgradeability, no early withdrawal.
///         The only escape hatch: if the bound pool has held zero liquidity
///         for 30 consecutive days (launch abandoned), the full remaining
///         balance unlocks — so tokens cannot be bricked forever.
///
///         Depth is approximated as the token-side amount within a +/-20%
///         price band around the current price, assuming the pool's active
///         liquidity across that band. Vaults may also be created unbound
///         (poolBound=false): the depth term is skipped and the drip is a
///         pure time schedule — this supports non-v4 pools.
contract DripVault {
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------- errors
    error CliffActive();
    error ExceedsReleasable();
    error FeeOnTransferToken();
    error PoolNotDead();
    error NotBound();
    error ZeroAmount();

    // ---------------------------------------------------------------- events
    event Deposited(address indexed from, uint256 amount, uint256 newAllocation);
    event Released(uint256 amount, uint256 totalReleased);
    event DeadPoolMarked(uint64 since);
    event DeadPoolCleared();
    event DeadPoolUnlocked(uint256 amount);

    // ---------------------------------------------------------------- config
    uint256 public constant BIPS = 10_000;
    uint256 public constant EPOCH = 1 days;
    uint256 public constant DEAD_POOL_DELAY = 30 days;
    /// +20% band: sqrt(1.2) and sqrt(1/1.2) scaled by 1e7
    uint256 private constant SQRT_BAND_UP = 10_954_451;
    uint256 private constant SQRT_BAND_DOWN = 9_128_709;
    uint256 private constant SQRT_SCALE = 10_000_000;

    IERC20 public immutable token;
    address public immutable devRecipient;
    uint64 public immutable createdAt;
    uint16 public immutable dripBips; // max release per epoch, bips of allocation
    uint16 public immutable depthBips; // max release per epoch, bips of pool depth
    uint32 public immutable cliffSeconds;
    bool public immutable poolBound;
    bool public immutable tokenIsZero;
    IPoolManager public immutable poolManager;
    PoolId public immutable poolId;

    // ----------------------------------------------------------------- state
    uint256 public allocation; // total ever deposited
    uint256 public released; // total ever released
    uint256 public lastEpoch;
    uint256 public releasedInEpoch;
    uint64 public deadSince;
    uint256 private _entered;

    /// defense-in-depth against reentrant (ERC777-style) tokens; such a token
    /// can only hurt its own vault, but the guard is cheap
    modifier nonReentrant() {
        require(_entered == 0, "reentrant");
        _entered = 1;
        _;
        _entered = 0;
    }

    struct VaultConfig {
        IERC20 token;
        address devRecipient;
        uint16 dripBips;
        uint16 depthBips;
        uint32 cliffSeconds;
        bool poolBound;
        bool tokenIsZero;
        IPoolManager poolManager;
        PoolId poolId;
    }

    constructor(VaultConfig memory cfg) {
        require(cfg.dripBips > 0 && cfg.dripBips <= BIPS, "dripBips");
        require(!cfg.poolBound || cfg.depthBips > 0, "depthBips");
        token = cfg.token;
        devRecipient = cfg.devRecipient;
        createdAt = uint64(block.timestamp);
        dripBips = cfg.dripBips;
        depthBips = cfg.depthBips;
        cliffSeconds = cfg.cliffSeconds;
        poolBound = cfg.poolBound;
        tokenIsZero = cfg.tokenIsZero;
        poolManager = cfg.poolManager;
        poolId = cfg.poolId;
    }

    // ----------------------------------------------------------- deposits

    /// @notice Escrow tokens. Anyone may deposit; deposits only ever raise the
    ///         allocation. Fee-on-transfer tokens are rejected.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = token.balanceOf(address(this));
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
        if (token.balanceOf(address(this)) - before != amount) revert FeeOnTransferToken();
        allocation += amount;
        emit Deposited(msg.sender, amount, allocation);
    }

    // ----------------------------------------------------------- release

    /// @notice Tokens releasable right now under the drip rule.
    function releasable() public view returns (uint256) {
        if (block.timestamp < uint256(createdAt) + cliffSeconds) return 0;
        uint256 cap = allocation * dripBips / BIPS;
        if (poolBound) {
            uint256 depthCap = poolDepth() * depthBips / BIPS;
            if (depthCap < cap) cap = depthCap;
        }
        uint256 used = currentEpoch() == lastEpoch ? releasedInEpoch : 0;
        uint256 avail = cap > used ? cap - used : 0;
        uint256 bal = token.balanceOf(address(this));
        return avail < bal ? avail : bal;
    }

    /// @notice Release escrowed tokens to devRecipient. Callable by anyone
    ///         (keeper-friendly); funds can only ever reach devRecipient.
    function release(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < uint256(createdAt) + cliffSeconds) revert CliffActive();
        if (amount > releasable()) revert ExceedsReleasable();
        uint256 epoch = currentEpoch();
        if (epoch != lastEpoch) {
            lastEpoch = epoch;
            releasedInEpoch = 0;
        }
        releasedInEpoch += amount;
        released += amount;
        require(token.transfer(devRecipient, amount), "transfer");
        emit Released(amount, released);
    }

    // ----------------------------------------------------- dead-pool escape

    /// @notice Start (or clear) the dead-pool timer. Anyone may poke.
    function pokeDead() external {
        if (!poolBound) revert NotBound();
        if (poolManager.getLiquidity(poolId) == 0) {
            if (deadSince == 0) {
                deadSince = uint64(block.timestamp);
                emit DeadPoolMarked(deadSince);
            }
        } else if (deadSince != 0) {
            deadSince = 0;
            emit DeadPoolCleared();
        }
    }

    /// @notice After 30 consecutive days of zero pool liquidity, the full
    ///         remaining balance unlocks to devRecipient.
    function unlockDead() external nonReentrant {
        if (!poolBound) revert NotBound();
        if (
            deadSince == 0 || block.timestamp < uint256(deadSince) + DEAD_POOL_DELAY
                || poolManager.getLiquidity(poolId) != 0
        ) revert PoolNotDead();
        uint256 bal = token.balanceOf(address(this));
        require(token.transfer(devRecipient, bal), "transfer");
        emit DeadPoolUnlocked(bal);
    }

    // ----------------------------------------------------------- view

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - createdAt) / EPOCH;
    }

    /// @notice Token-side depth: the token amount inside a 20% price band
    ///         adjacent to the current price, at the pool's active liquidity.
    function poolDepth() public view returns (uint256) {
        if (!poolBound) return 0;
        uint128 liquidity = poolManager.getLiquidity(poolId);
        if (liquidity == 0) return 0;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) return 0;
        if (tokenIsZero) {
            // token0 depth lies above the current price
            uint256 upper = uint256(sqrtPriceX96) * SQRT_BAND_UP / SQRT_SCALE;
            if (upper > TickMath.MAX_SQRT_PRICE) upper = TickMath.MAX_SQRT_PRICE;
            return SqrtPriceMath.getAmount0Delta(sqrtPriceX96, uint160(upper), liquidity, false);
        } else {
            // token1 depth lies below the current price
            uint256 lower = uint256(sqrtPriceX96) * SQRT_BAND_DOWN / SQRT_SCALE;
            if (lower < TickMath.MIN_SQRT_PRICE) lower = TickMath.MIN_SQRT_PRICE;
            return SqrtPriceMath.getAmount1Delta(uint160(lower), sqrtPriceX96, liquidity, false);
        }
    }

    /// @notice One-call read for scanners and token pages.
    function status()
        external
        view
        returns (uint256 _allocation, uint256 _released, uint256 _releasableNow, uint256 _balance, uint256 _depth)
    {
        return (allocation, released, releasable(), token.balanceOf(address(this)), poolDepth());
    }
}
