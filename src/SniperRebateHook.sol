// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @title SniperRebateHook v2 ("Robin Hood")
/// @notice During a protection period after pool creation, every sell pays a
///         linearly declining tax. 90% fills a pot that opening-window buyers
///         who held claim pro-rata; a fixed 10% accrues to the PumpPill
///         treasury. Unclaimed pots sweep to the treasury after the claim
///         window. Outside the protection period the hook is inert: 0 extra
///         fee, forever.
///
///         v2 changes over the deployed v1 (0x092e…5044, now deprecated):
///         - protocol fee (PROTOCOL_FEE_BIPS, hard-coded) accrues PULL-style:
///           fees build inside the hook and claimProtocolFees() sweeps them —
///           nothing on the swap path ever pushes to an external address, so
///           a reverting treasury can never brick a pool.
///         - treasury is rotatable, but ONLY by the current treasury key.
///           That controls where protocol fees land and nothing else — user
///           funds and pool mechanics have no admin surface.
///         - per-pool parameters: the pool creator may tune tax/windows within
///           hard caps until trading starts (grace period applies for pools
///           needing manual configuration). Defaults are PumpPill-calibrated.
///         - any quote asset: ETH/WETH pools auto-configure; stock- or
///           token-quoted pools (SNAPI-class, HOOKR-quoted) activate when the
///           creator declares which side is the launch token.
///         - on-chain pool registry (allPools) for usage evidence.
///
///         Known v1 limitations that remain (documented, accepted): buyer
///         attribution uses tx.origin, and the hook cannot see plain token
///         transfers, so a buyer can move tokens to a mule and still claim —
///         but the mule's sell pays the tax, leaving that game ~net-neutral.
contract SniperRebateHook is IHooks {
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;

    // ---------------------------------------------------------------- errors
    error NotPoolManager();
    error HookNotImplemented();
    error NotCreator();
    error NotTreasury();
    error AlreadyTrading();
    error ConfigWindowClosed();
    error BadParams();
    error PoolNotActive();
    error ProtectionNotOver();
    error ClaimWindowClosed();
    error ClaimWindowOpen();
    error NothingToClaim();
    error AlreadyClaimed();
    error AlreadySwept();
    error UnknownPool();
    error ZeroAddress();

    // ---------------------------------------------------------------- events
    event PoolRegistered(PoolId indexed poolId, address indexed creator, bool autoConfigured);
    event PoolConfigured(
        PoolId indexed poolId, bool tokenIsZero, uint32 startTaxBips, uint32 protectionSeconds, uint32 trackWindowSeconds
    );
    event BuyTracked(PoolId indexed poolId, address indexed buyer, uint128 amount);
    event SellTaxed(
        PoolId indexed poolId, address indexed seller, Currency feeCurrency, uint256 potShare, uint256 treasuryShare
    );
    event Claimed(PoolId indexed poolId, address indexed holder, uint256 quoteOut, uint256 tokenOut);
    event SweptToTreasury(PoolId indexed poolId, uint256 quoteAmount, uint256 tokenAmount);
    event ProtocolFeesClaimed(Currency indexed currency, address indexed treasury, uint256 amount);
    event TreasuryRotated(address indexed oldTreasury, address indexed newTreasury);

    // ---------------------------------------------------------------- config
    uint256 public constant BIPS = 10_000;
    /// hard-coded protocol share of every tax collection; no admin can change it
    uint256 public constant PROTOCOL_FEE_BIPS = 1_000; // 10%
    uint256 public constant MAX_TAX_BIPS = 3_000; // per-pool cap: 30%
    uint256 public constant MAX_PROTECTION = 24 hours; // per-pool cap

    IPoolManager public immutable poolManager;
    address public immutable weth;
    // PumpPill-calibrated defaults; pools may tune within the caps above
    uint32 public immutable defaultTaxBips;
    uint32 public immutable defaultProtectionSeconds;
    uint32 public immutable defaultTrackWindowSeconds;
    uint256 public immutable claimWindowSeconds;

    /// where protocol fees land. Rotatable ONLY by itself (key rotation /
    /// future multisig), never by anyone else — this is not an admin key over
    /// user funds or pool behavior.
    address public treasury;

    // ----------------------------------------------------------------- state
    struct PoolState {
        uint64 initAt;
        bool tokenIsZero;
        bool active; // configured (auto or by creator)
        bool traded; // first swap seen — locks reconfiguration
        bool swept;
        Currency quoteCur;
        Currency tokenCur;
        address creator; // tx.origin at initialize
        uint32 startTaxBips;
        uint32 protectionSeconds;
        uint32 trackWindowSeconds;
        uint128 potQuote; // remaining (decremented on claims)
        uint128 potToken; // remaining (decremented on claims)
        uint128 totalEligible; // claim denominator, frozen once protection ends
    }

    // internal + struct getter below: the auto-generated 14-tuple getter is
    // stack-too-deep on the legacy pipeline, and a struct return is nicer for
    // scanners anyway
    mapping(PoolId => PoolState) internal _pools;
    mapping(PoolId => mapping(address => uint128)) public netBought;
    mapping(PoolId => mapping(address => bool)) public claimed;
    /// accrued protocol fees per currency, swept by claimProtocolFees()
    mapping(Currency => uint256) public protocolFees;
    /// every pool ever initialized against this hook — public usage evidence
    PoolId[] public allPools;

    constructor(
        IPoolManager _poolManager,
        address _weth,
        address _treasury,
        uint32 _defaultTaxBips,
        uint32 _defaultProtectionSeconds,
        uint32 _defaultTrackWindowSeconds,
        uint256 _claimWindowSeconds
    ) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_defaultTaxBips > MAX_TAX_BIPS || _defaultProtectionSeconds > MAX_PROTECTION) revert BadParams();
        if (_defaultTrackWindowSeconds > _defaultProtectionSeconds) revert BadParams();
        poolManager = _poolManager;
        weth = _weth;
        treasury = _treasury;
        defaultTaxBips = _defaultTaxBips;
        defaultProtectionSeconds = _defaultProtectionSeconds;
        defaultTrackWindowSeconds = _defaultTrackWindowSeconds;
        claimWindowSeconds = _claimWindowSeconds;
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// take() of native ETH pays the hook directly
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    // ------------------------------------------------------------- callbacks

    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        PoolId id = key.toId();
        PoolState storage s = _pools[id];
        s.initAt = uint64(block.timestamp);
        // tx.origin, not the callback sender: pools are usually initialized
        // through a position manager or launchpad, which would otherwise be
        // "creator" for every pool it touches.
        s.creator = tx.origin;
        s.startTaxBips = defaultTaxBips;
        s.protectionSeconds = defaultProtectionSeconds;
        s.trackWindowSeconds = defaultTrackWindowSeconds;
        allPools.push(id);

        // ETH/WETH pools auto-configure; anything else (stock-quoted,
        // HOOKR-quoted) waits for the creator to declare the token side.
        bool zeroIsQuote = key.currency0.isAddressZero() || Currency.unwrap(key.currency0) == weth;
        bool oneIsQuote = Currency.unwrap(key.currency1) == weth;
        if (zeroIsQuote != oneIsQuote) {
            s.tokenIsZero = oneIsQuote;
            s.quoteCur = zeroIsQuote ? key.currency0 : key.currency1;
            s.tokenCur = zeroIsQuote ? key.currency1 : key.currency0;
            s.active = true;
        } else {
            // remember the pair so configure() can assign sides later
            s.quoteCur = key.currency0;
            s.tokenCur = key.currency1;
        }
        emit PoolRegistered(id, s.creator, s.active);
        return IHooks.afterInitialize.selector;
    }

    /// @notice Pool creator tunes this pool's protection within hard caps, and
    ///         (for non-ETH-quoted pairs) declares which side is the token.
    ///         Allowed until trading starts; an inactive pool keeps a grace
    ///         window equal to its track window even if someone dust-swaps it
    ///         first, so a griefer cannot permanently disable protection.
    function configure(
        PoolId id,
        bool tokenIsZero,
        uint32 startTaxBips_,
        uint32 protectionSeconds_,
        uint32 trackWindowSeconds_
    ) external {
        PoolState storage s = _pools[id];
        if (s.initAt == 0) revert UnknownPool();
        if (msg.sender != s.creator) revert NotCreator();
        if (s.active && s.traded) revert AlreadyTrading();
        if (!s.active && s.traded && block.timestamp - s.initAt > s.trackWindowSeconds) {
            revert ConfigWindowClosed();
        }
        if (startTaxBips_ > MAX_TAX_BIPS || protectionSeconds_ > MAX_PROTECTION) revert BadParams();
        if (trackWindowSeconds_ > protectionSeconds_) revert BadParams();

        // reassign sides: quoteCur/tokenCur were stored as (currency0,
        // currency1) for non-auto pools and as (quote, token) for auto pools —
        // normalize from the declared token side either way.
        (Currency c0, Currency c1) = s.tokenIsZero
            ? (s.tokenCur, s.quoteCur)
            : (s.quoteCur, s.tokenCur);
        s.tokenIsZero = tokenIsZero;
        s.quoteCur = tokenIsZero ? c1 : c0;
        s.tokenCur = tokenIsZero ? c0 : c1;
        s.startTaxBips = startTaxBips_;
        s.protectionSeconds = protectionSeconds_;
        s.trackWindowSeconds = trackWindowSeconds_;
        s.active = true;
        emit PoolConfigured(id, tokenIsZero, startTaxBips_, protectionSeconds_, trackWindowSeconds_);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();
        PoolState storage s = _pools[id];
        if (s.initAt == 0) return (IHooks.afterSwap.selector, 0);
        if (!s.traded) s.traded = true;
        if (!s.active) return (IHooks.afterSwap.selector, 0);

        // sell = the launch token is the input currency of the swap
        if (params.zeroForOne != s.tokenIsZero) {
            _trackBuy(id, s, delta);
            return (IHooks.afterSwap.selector, 0);
        }
        return (IHooks.afterSwap.selector, _handleSell(id, s, key, params, delta));
    }

    /// buy during the opening window: track eligibility for the rebate claim
    function _trackBuy(PoolId id, PoolState storage s, BalanceDelta delta) internal {
        if (block.timestamp - s.initAt > s.trackWindowSeconds) return;
        int128 tokenDelta = s.tokenIsZero ? delta.amount0() : delta.amount1();
        if (tokenDelta <= 0) return;
        uint128 amt = uint128(tokenDelta);
        netBought[id][tx.origin] += amt;
        s.totalEligible += amt;
        emit BuyTracked(id, tx.origin, amt);
    }

    function _handleSell(
        PoolId id,
        PoolState storage s,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta
    ) internal returns (int128) {
        uint256 elapsed = block.timestamp - s.initAt;
        // after protection the hook is inert forever (eligibility frozen too)
        if (elapsed >= s.protectionSeconds) return 0;

        // forfeit claim eligibility for whatever was sold
        {
            uint128 net = netBought[id][tx.origin];
            if (net > 0) {
                int128 tokenDelta = s.tokenIsZero ? delta.amount0() : delta.amount1();
                uint128 sold = uint128(tokenDelta < 0 ? -tokenDelta : tokenDelta);
                uint128 dec = sold < net ? sold : net;
                netBought[id][tx.origin] = net - dec;
                s.totalEligible -= dec;
            }
        }

        // declining tax, taken from the unspecified currency (quote-side for
        // the standard exact-input sell), FeeTakingHook pattern
        uint256 taxBips = uint256(s.startTaxBips) * (s.protectionSeconds - elapsed) / s.protectionSeconds;
        if (taxBips == 0) return 0;

        (Currency feeCurrency, uint256 swapAmount) = _feeCurrencyAndAmount(key, params, delta);
        uint256 feeAmount = swapAmount * taxBips / BIPS;
        if (feeAmount == 0) return 0;

        _takeAndSplit(id, s, feeCurrency, feeAmount);
        return feeAmount.toInt128();
    }

    /// fee lands on the unspecified currency of the swap
    function _feeCurrencyAndAmount(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        internal
        pure
        returns (Currency feeCurrency, uint256 amount)
    {
        bool specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);
        int128 swapAmount;
        (feeCurrency, swapAmount) =
            specifiedTokenIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        if (swapAmount < 0) swapAmount = -swapAmount;
        amount = uint256(uint128(swapAmount));
    }

    /// take the full fee into the hook, then split: 90% pot / 10% protocol.
    /// Protocol fees only ever ACCRUE here — nothing on the swap path sends
    /// to an external address, so a reverting treasury cannot brick a pool.
    function _takeAndSplit(PoolId id, PoolState storage s, Currency feeCurrency, uint256 feeAmount) internal {
        poolManager.take(feeCurrency, address(this), feeAmount);
        uint256 treasuryShare = feeAmount * PROTOCOL_FEE_BIPS / BIPS;
        uint256 potShare = feeAmount - treasuryShare;
        protocolFees[feeCurrency] += treasuryShare;
        if (Currency.unwrap(feeCurrency) == Currency.unwrap(s.tokenCur)) {
            s.potToken += potShare.toUint128();
        } else {
            s.potQuote += potShare.toUint128();
        }
        emit SellTaxed(id, tx.origin, feeCurrency, potShare, treasuryShare);
    }

    // ----------------------------------------------------------- claims

    /// @notice Claim the caller's pro-rata share of the pot. Open from the end
    ///         of the protection period until the claim window closes.
    function claim(PoolId id) external {
        PoolState storage s = _pools[id];
        if (s.initAt == 0) revert UnknownPool();
        if (!s.active) revert PoolNotActive();
        uint256 protectionEnd = uint256(s.initAt) + s.protectionSeconds;
        if (block.timestamp < protectionEnd) revert ProtectionNotOver();
        if (block.timestamp > protectionEnd + claimWindowSeconds) revert ClaimWindowClosed();
        if (claimed[id][msg.sender]) revert AlreadyClaimed();

        uint128 net = netBought[id][msg.sender];
        if (net == 0 || s.totalEligible == 0) revert NothingToClaim();

        claimed[id][msg.sender] = true;
        uint256 quoteOut = uint256(s.potQuote) * net / s.totalEligible;
        uint256 tokenOut = uint256(s.potToken) * net / s.totalEligible;
        // shrink pot and denominator together so later claimants keep their ratio
        s.potQuote -= quoteOut.toUint128();
        s.potToken -= tokenOut.toUint128();
        s.totalEligible -= net;

        if (quoteOut > 0) s.quoteCur.transfer(msg.sender, quoteOut);
        if (tokenOut > 0) s.tokenCur.transfer(msg.sender, tokenOut);
        emit Claimed(id, msg.sender, quoteOut, tokenOut);
    }

    /// @notice After the claim window closes, anyone may sweep the unclaimed
    ///         pot into accrued protocol fees (pull-claimed by the treasury).
    function sweep(PoolId id) external {
        PoolState storage s = _pools[id];
        if (s.initAt == 0) revert UnknownPool();
        if (block.timestamp <= uint256(s.initAt) + s.protectionSeconds + claimWindowSeconds) {
            revert ClaimWindowOpen();
        }
        if (s.swept) revert AlreadySwept();
        s.swept = true;
        uint256 quoteAmt = s.potQuote;
        uint256 tokenAmt = s.potToken;
        s.potQuote = 0;
        s.potToken = 0;
        if (quoteAmt > 0) protocolFees[s.quoteCur] += quoteAmt;
        if (tokenAmt > 0) protocolFees[s.tokenCur] += tokenAmt;
        emit SweptToTreasury(id, quoteAmt, tokenAmt);
    }

    // ----------------------------------------------------------- treasury

    /// @notice Sweep accrued protocol fees for one currency to the treasury.
    ///         Callable by anyone (keeper-friendly); funds only ever reach the
    ///         treasury.
    function claimProtocolFees(Currency currency) external {
        uint256 amount = protocolFees[currency];
        if (amount == 0) revert NothingToClaim();
        protocolFees[currency] = 0;
        currency.transfer(treasury, amount);
        emit ProtocolFeesClaimed(currency, treasury, amount);
    }

    /// @notice Rotate the treasury. Only the current treasury key may do this —
    ///         it controls where protocol fees land and nothing else.
    function setTreasury(address newTreasury) external {
        if (msg.sender != treasury) revert NotTreasury();
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryRotated(treasury, newTreasury);
        treasury = newTreasury;
    }

    // ----------------------------------------------------------- view

    function currentTaxBips(PoolId id) external view returns (uint256) {
        PoolState storage s = _pools[id];
        if (s.initAt == 0 || !s.active) return 0;
        uint256 elapsed = block.timestamp - s.initAt;
        if (elapsed >= s.protectionSeconds) return 0;
        return uint256(s.startTaxBips) * (s.protectionSeconds - elapsed) / s.protectionSeconds;
    }

    function poolCount() external view returns (uint256) {
        return allPools.length;
    }

    function pools(PoolId id) external view returns (PoolState memory) {
        return _pools[id];
    }

    // ------------------------------------------- unused callbacks (never called)

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
