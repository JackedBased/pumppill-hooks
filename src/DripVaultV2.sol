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

/// @title DripVaultV2 ("Dev-Drip")
/// @notice Escrow for a creator's token bag with a pool-aware, rate-limited
///         release. Per 24h epoch the vault releases at most
///         min(dripBips of matured allocation, depthBips of live pool depth).
///         Releases go only to the immutable devRecipient.
///
///         No owner, no admin, no upgradeability, no early withdrawal. The
///         only escape hatch: if the bound pool has held zero liquidity for 30
///         consecutive days (launch abandoned), the remaining balance unlocks,
///         so tokens cannot be bricked forever.
///
/// @dev    What changed from v1, and why
///
///         v1 measured the cliff from `createdAt` alone. Every deposit shared
///         that one clock, so a deposit made after the cliff expired was
///         releasable the same day — "locked" was not true for anything
///         deposited late. v1 also let anyone deposit, and sized the per-epoch
///         cap off total allocation, so a third party could both inflate the
///         published allocation and raise the drip rate on a bag that was
///         already escrowed.
///
///         v2 fixes both. Every deposit is its own tranche with its own unlock
///         time, and only matured tranches count toward either the releasable
///         balance or the per-epoch cap. Deposits may be restricted to a single
///         immutable address — normally the buy-and-escrow router, which makes
///         "every token in here was bought on the open market" a property of
///         the contract rather than a claim about the creator.
///
///         Tranches mature strictly in deposit order, because cliffSeconds is
///         constant, so maturity is tracked with a cursor that only moves
///         forward. Each tranche is walked once in its life rather than on
///         every call, and MAX_TRANCHES plus minDeposit bound the one call that
///         has to absorb a backlog.
contract DripVaultV2 {
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------- errors
    error CliffActive();
    error DepositTooSmall();
    error ExceedsReleasable();
    error FeeOnTransferToken();
    error NotDepositor();
    error PoolNotDead();
    error NotBound();
    error TooManyTranches();
    error ZeroAmount();

    // ---------------------------------------------------------------- events
    event Deposited(address indexed from, uint256 amount, uint64 unlockAt, uint256 newAllocation);
    event Released(uint256 amount, uint256 totalReleased);
    event DeadPoolMarked(uint64 since);
    event DeadPoolCleared();
    event DeadPoolUnlocked(uint256 amount);

    // ---------------------------------------------------------------- config
    uint256 public constant BIPS = 10_000;
    uint256 public constant EPOCH = 1 days;
    uint256 public constant DEAD_POOL_DELAY = 30 days;
    /// Bounds the single release() that has to absorb a backlog of tranches
    /// that all matured since the last one.
    uint256 public constant MAX_TRANCHES = 64;
    /// +20% band: sqrt(1.2) and sqrt(1/1.2) scaled by 1e7
    uint256 private constant SQRT_BAND_UP = 10_954_451;
    uint256 private constant SQRT_BAND_DOWN = 9_128_709;
    uint256 private constant SQRT_SCALE = 10_000_000;

    IERC20 public immutable token;
    /// The only address tokens can ever reach. Not rotatable.
    address public immutable devRecipient;
    /// The only address that may deposit. address(0) means anyone may.
    address public immutable depositor;
    uint64 public immutable createdAt;
    uint16 public immutable dripBips; // max release per epoch, bips of matured allocation
    uint16 public immutable depthBips; // max release per epoch, bips of pool depth
    uint32 public immutable cliffSeconds; // per-tranche, measured from its own deposit
    uint256 public immutable minDeposit;
    bool public immutable poolBound;
    bool public immutable tokenIsZero;
    IPoolManager public immutable poolManager;
    PoolId public immutable poolId;

    // ----------------------------------------------------------------- state
    struct Tranche {
        uint128 amount;
        uint64 unlockAt;
    }

    Tranche[] public tranches;

    uint256 public allocation; // total ever deposited, matured or not
    uint256 public released; // total ever released
    uint256 public lastEpoch;
    uint256 public releasedInEpoch;
    uint64 public deadSince;

    /// Index of the first tranche not yet folded into `maturedAmount`.
    uint256 public maturedCursor;
    /// Sum of tranches[0 .. maturedCursor-1].
    uint256 public maturedAmount;

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
        address depositor;
        uint16 dripBips;
        uint16 depthBips;
        uint32 cliffSeconds;
        uint256 minDeposit;
        bool poolBound;
        bool tokenIsZero;
        IPoolManager poolManager;
        PoolId poolId;
    }

    constructor(VaultConfig memory cfg) {
        require(cfg.dripBips > 0 && cfg.dripBips <= BIPS, "dripBips");
        require(!cfg.poolBound || cfg.depthBips > 0, "depthBips");
        require(cfg.devRecipient != address(0), "devRecipient");
        token = cfg.token;
        devRecipient = cfg.devRecipient;
        depositor = cfg.depositor;
        createdAt = uint64(block.timestamp);
        dripBips = cfg.dripBips;
        depthBips = cfg.depthBips;
        cliffSeconds = cfg.cliffSeconds;
        minDeposit = cfg.minDeposit;
        poolBound = cfg.poolBound;
        tokenIsZero = cfg.tokenIsZero;
        poolManager = cfg.poolManager;
        poolId = cfg.poolId;
    }

    // ----------------------------------------------------------- deposits

    /// @notice Escrow tokens as a new tranche, unlocking cliffSeconds from now.
    ///         Deposits only ever raise the allocation; there is no withdrawal
    ///         path for a depositor, so a deposit by anyone other than the
    ///         creator is a donation to devRecipient on the same drip schedule.
    ///         Fee-on-transfer tokens are rejected outright — a vault whose
    ///         accounting and balance disagree cannot honour its own cap.
    function deposit(uint256 amount) external nonReentrant {
        if (depositor != address(0) && msg.sender != depositor) revert NotDepositor();
        if (amount == 0) revert ZeroAmount();
        if (amount < minDeposit) revert DepositTooSmall();
        if (tranches.length >= MAX_TRANCHES) revert TooManyTranches();

        uint256 before = token.balanceOf(address(this));
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom");
        if (token.balanceOf(address(this)) - before != amount) revert FeeOnTransferToken();

        uint64 unlockAt = uint64(block.timestamp) + cliffSeconds;
        tranches.push(Tranche({amount: uint128(amount), unlockAt: unlockAt}));
        allocation += amount;
        emit Deposited(msg.sender, amount, unlockAt, allocation);
    }

    // ----------------------------------------------------------- release

    /// @notice Total deposited whose own cliff has passed. Everything else is
    ///         invisible to the release path: an immature tranche neither pays
    ///         out nor raises the per-epoch cap.
    function maturedAllocation() public view returns (uint256 m) {
        m = maturedAmount;
        uint256 n = tranches.length;
        for (uint256 i = maturedCursor; i < n; ++i) {
            if (tranches[i].unlockAt > block.timestamp) break;
            m += tranches[i].amount;
        }
    }

    /// @notice Tokens releasable right now under the drip rule.
    function releasable() public view returns (uint256) {
        uint256 matured = maturedAllocation();
        if (matured <= released) return 0;

        uint256 cap = matured * dripBips / BIPS;
        if (poolBound) {
            uint256 depthCap = poolDepth() * depthBips / BIPS;
            if (depthCap < cap) cap = depthCap;
        }
        uint256 used = currentEpoch() == lastEpoch ? releasedInEpoch : 0;
        uint256 avail = cap > used ? cap - used : 0;

        uint256 remaining = matured - released;
        if (avail > remaining) avail = remaining;
        uint256 bal = token.balanceOf(address(this));
        return avail < bal ? avail : bal;
    }

    /// @notice Release escrowed tokens to devRecipient. Callable by anyone
    ///         (keeper-friendly); funds can only ever reach devRecipient.
    function release(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrue();
        if (maturedAmount == 0) revert CliffActive();
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

    /// @dev Fold every tranche that has matured into the running total. Each
    ///      tranche is visited once in the life of the vault.
    function _accrue() internal {
        uint256 i = maturedCursor;
        uint256 n = tranches.length;
        uint256 add;
        while (i < n && tranches[i].unlockAt <= block.timestamp) {
            add += tranches[i].amount;
            unchecked {
                ++i;
            }
        }
        if (i != maturedCursor) {
            maturedCursor = i;
            maturedAmount += add;
        }
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

    /// @notice After 30 consecutive days of zero pool liquidity the remaining
    ///         balance unlocks to devRecipient, immature tranches included.
    ///         The cliff protects buyers in a live market; there is no market
    ///         left to protect here, and the alternative is burning someone's
    ///         tokens for the crime of launching into a pool that died.
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

    function trancheCount() external view returns (uint256) {
        return tranches.length;
    }

    /// @notice Unlock time of the earliest tranche still immature, or 0 if
    ///         everything deposited so far has matured.
    function nextUnlockAt() public view returns (uint64) {
        uint256 n = tranches.length;
        for (uint256 i = maturedCursor; i < n; ++i) {
            if (tranches[i].unlockAt > block.timestamp) return tranches[i].unlockAt;
        }
        return 0;
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
        returns (
            uint256 _allocation,
            uint256 _matured,
            uint256 _released,
            uint256 _releasableNow,
            uint256 _balance,
            uint256 _depth,
            uint64 _nextUnlockAt
        )
    {
        return (
            allocation,
            maturedAllocation(),
            released,
            releasable(),
            token.balanceOf(address(this)),
            poolDepth(),
            nextUnlockAt()
        );
    }
}
