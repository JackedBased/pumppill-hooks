// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {DripVaultV2} from "./DripVaultV2.sol";

interface IERC20Minimal {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title BuyAndEscrowRouter
/// @notice Buys a token on the open market and escrows the whole proceeds into
///         a DripVaultV2, in one transaction that either does both or does
///         neither.
///
///         This exists because of what a launch actually looks like when the
///         full supply goes into the LP position: there is no reserved creator
///         allocation to escrow. The creator's bag has to be bought like
///         anyone else's. Buying and then choosing whether to lock is a
///         promise; buying and locking in the same transaction is a fact, and
///         the difference is the entire value of the badge.
///
///         To be explicit about what the buy does and does not do: it moves
///         the pool along its curve, changing reserves and price. It does not
///         mint liquidity and it does not add depth. What it produces is a
///         paid-for bag that is locked — nothing more is claimed for it.
///
/// @dev    Deliberately feeless. Dev-Drip has never charged, and a fee here
///         would be a tax on the one behaviour the whole design is trying to
///         make attractive. Revenue is SniperRebateHook's business.
///
///         Unlike PPSwapRouter, this contract does hold tokens — for the
///         length of one transaction, between `take` and `deposit`, because
///         the vault's accounting is driven by transferFrom and tokens pushed
///         straight to it would land outside every tranche. Anything left here
///         when the transaction ends is a bug; `sweep` undoes that bug and
///         sends to the vault's own devRecipient, never to us.
///
///         The swap runs through the ordinary path with the pool's hook
///         attached, so anti-snipe caps, opening-window fees and every other
///         launch guard see this buy exactly as they see any other. The router
///         asks for no exemption and should never be granted one: an escrow
///         route that bypasses the buy guards would be a hole wearing a badge.
contract BuyAndEscrowRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;

    error Expired();
    error NotPoolManager();
    error NothingSent();
    error TokenNotInPool();
    error VaultTokenMismatch();
    error VaultRejectsRouter();
    error NothingReceived();
    error TooLittleEscrowed(uint256 got, uint256 minEscrowed);
    error EscrowAccountingMismatch(uint256 expected, uint256 actual);
    error RefundFailed();

    event BoughtAndEscrowed(
        address indexed caller,
        address indexed vault,
        address indexed beneficiary,
        address token,
        uint256 amountIn,
        uint256 escrowed
    );

    IPoolManager public immutable poolManager;

    struct SwapCall {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        bytes hookData;
    }

    uint256 private _entered;

    modifier nonReentrant() {
        require(_entered == 0, "reentrant");
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    // ------------------------------------------------------------ entrypoints

    /// @notice Buy `vault`'s token with the ETH sent and escrow all of it.
    /// @param minEscrowed revert unless at least this much reaches the vault —
    ///        the slippage guard binds on the escrowed amount, not on the swap
    ///        output, so the number the caller sees is the number that sticks.
    function buyAndEscrowWithETH(PoolKey calldata key, DripVaultV2 vault, uint256 minEscrowed, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 escrowed)
    {
        if (block.timestamp > deadline) revert Expired();
        if (msg.value == 0) revert NothingSent();
        escrowed = _buyAndEscrow(key, vault, msg.value, minEscrowed);
    }

    /// @notice Buy `vault`'s token with an ERC20 quote currency (a HOOKR-quoted
    ///         pair, say) and escrow all of it. The caller must have approved
    ///         this router for `amountIn` of the quote token.
    function buyAndEscrowWithToken(
        PoolKey calldata key,
        DripVaultV2 vault,
        uint256 amountIn,
        uint256 minEscrowed,
        uint256 deadline
    ) external nonReentrant returns (uint256 escrowed) {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert NothingSent();

        Currency quote = _quoteCurrency(key, address(vault.token()));
        if (quote.isAddressZero()) revert NothingSent(); // use the ETH entrypoint
        require(
            IERC20Minimal(Currency.unwrap(quote)).transferFrom(msg.sender, address(this), amountIn), "quoteTransferFrom"
        );
        escrowed = _buyAndEscrow(key, vault, amountIn, minEscrowed);
    }

    // ---------------------------------------------------------------- internal

    function _quoteCurrency(PoolKey calldata key, address token) internal pure returns (Currency) {
        if (Currency.unwrap(key.currency0) == token) return key.currency1;
        if (Currency.unwrap(key.currency1) == token) return key.currency0;
        revert TokenNotInPool();
    }

    /// @dev Split into small helpers on purpose: the whole path in one frame
    ///      is stack-too-deep on the legacy pipeline, and via-IR is not an
    ///      option here because it breaks the v4-core Pool library under test.
    function _buyAndEscrow(PoolKey calldata key, DripVaultV2 vault, uint256 amountIn, uint256 minEscrowed)
        internal
        returns (uint256 escrowed)
    {
        (address token, bool zeroForOne) = _validate(key, vault);
        uint256 received = _swapAndMeasure(key, vault, token, zeroForOne, amountIn);
        escrowed = _escrow(vault, token, received, minEscrowed);
        _refundUnspent(zeroForOne ? key.currency0 : key.currency1, amountIn);
        emit BoughtAndEscrowed(
            msg.sender, address(vault), vault.devRecipient(), token, amountIn, escrowed
        );
    }

    /// @dev Everything that can be known to be wrong before any money moves.
    function _validate(PoolKey calldata key, DripVaultV2 vault)
        internal
        view
        returns (address token, bool zeroForOne)
    {
        token = address(vault.token());
        bool tokenIsZero;
        if (Currency.unwrap(key.currency0) == token) tokenIsZero = true;
        else if (Currency.unwrap(key.currency1) != token) revert TokenNotInPool();

        // A vault bound to one pool must not be funded out of another: its
        // depth cap reads the bound pool, so buying somewhere thinner (or
        // somewhere fabricated) would size the drip off a pool the escrow has
        // nothing to do with.
        if (vault.poolBound() && PoolId.unwrap(vault.poolId()) != PoolId.unwrap(key.toId())) {
            revert VaultTokenMismatch();
        }

        // Fail early and legibly rather than reverting deep inside the vault.
        address gate = vault.depositor();
        if (gate != address(0) && gate != address(this)) revert VaultRejectsRouter();

        // Buying the token means paying with the other side of the pair.
        zeroForOne = !tokenIsZero;
    }

    /// @dev Swap, then report what actually landed here — measured on this
    ///      contract's own balance rather than taken from the swap's reported
    ///      delta or from any quote. A token that delivers less than it says,
    ///      or a partial fill against a thin range, escrows what truly arrived
    ///      and nothing else.
    function _swapAndMeasure(
        PoolKey calldata key,
        DripVaultV2 vault,
        address token,
        bool zeroForOne,
        uint256 amountIn
    ) internal returns (uint256 received) {
        // The vault receives the tokens; the creator is who the buy is *for*.
        // Attribution-aware hooks are handed the beneficiary explicitly, so a
        // cohort or rebate credits the human rather than an escrow contract.
        // Nothing here reads tx.origin, and nothing here should.
        bytes memory hookData = abi.encode(vault.devRecipient());

        uint256 balBefore = IERC20Minimal(token).balanceOf(address(this));
        poolManager.unlock(
            abi.encode(SwapCall({key: key, zeroForOne: zeroForOne, amountIn: amountIn, hookData: hookData}))
        );
        received = IERC20Minimal(token).balanceOf(address(this)) - balBefore;
        if (received == 0) revert NothingReceived();
    }

    /// @dev The escrow leg. No try/catch anywhere on this path: a failed
    ///      deposit takes the buy down with it. A creator must never end up
    ///      holding a free-floating bag because the escrow leg reverted
    ///      quietly — that is precisely the outcome the badge denies.
    function _escrow(DripVaultV2 vault, address token, uint256 received, uint256 minEscrowed)
        internal
        returns (uint256 escrowed)
    {
        if (received < minEscrowed) revert TooLittleEscrowed(received, minEscrowed);

        uint256 allocBefore = vault.allocation();
        IERC20Minimal(token).approve(address(vault), 0);
        IERC20Minimal(token).approve(address(vault), received);
        vault.deposit(received);
        IERC20Minimal(token).approve(address(vault), 0);

        uint256 credited = vault.allocation() - allocBefore;
        if (credited != received) revert EscrowAccountingMismatch(received, credited);
        escrowed = received;
    }

    /// @dev A swap stops at the edge of available liquidity rather than always
    ///      consuming its input. Thin pools are the normal case on Robinhood
    ///      Chain, so the remainder is returned to the caller instead of being
    ///      stranded here.
    function _refundUnspent(Currency inCurrency, uint256 amountIn) internal {
        if (inCurrency.isAddressZero()) {
            uint256 unspent = address(this).balance;
            if (unspent > 0) {
                (bool ok,) = msg.sender.call{value: unspent}("");
                if (!ok) revert RefundFailed();
            }
        } else {
            IERC20Minimal quote = IERC20Minimal(Currency.unwrap(inCurrency));
            uint256 bal = quote.balanceOf(address(this));
            uint256 unspent = bal < amountIn ? bal : amountIn;
            if (unspent > 0) require(quote.transfer(msg.sender, unspent), "refund");
        }
    }

    // ---------------------------------------------------------------- callback

    /// @dev The PoolManager calls this back inside unlock(). Everything that
    ///      touches the pool happens here and nowhere else.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        SwapCall memory c = abi.decode(data, (SwapCall));

        BalanceDelta delta = poolManager.swap(
            c.key,
            SwapParams({
                zeroForOne: c.zeroForOne,
                amountSpecified: -int256(c.amountIn), // negative = exact input
                sqrtPriceLimitX96: c.zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
            }),
            c.hookData
        );

        int128 owed = c.zeroForOne ? delta.amount0() : delta.amount1();
        int128 gained = c.zeroForOne ? delta.amount1() : delta.amount0();

        Currency inCurrency = c.zeroForOne ? c.key.currency0 : c.key.currency1;
        Currency outCurrency = c.zeroForOne ? c.key.currency1 : c.key.currency0;

        if (owed < 0) {
            uint256 amount = uint256(uint128(-owed));
            poolManager.sync(inCurrency);
            if (inCurrency.isAddressZero()) {
                poolManager.settle{value: amount}();
            } else {
                IERC20Minimal(Currency.unwrap(inCurrency)).transfer(address(poolManager), amount);
                poolManager.settle();
            }
        }

        uint256 out;
        if (gained > 0) {
            out = uint256(uint128(gained));
            // Taken here rather than straight to the vault: the vault's
            // accounting runs on transferFrom, and a token pushed directly to
            // it would sit outside every tranche, unlocked and uncounted.
            poolManager.take(outCurrency, address(this), out);
        }
        return abi.encode(out);
    }

    /// @notice Push out anything stranded here. The router is not supposed to
    ///         hold a balance between transactions; if it does, something went
    ///         wrong. Stranded tokens go to the vault's own devRecipient and
    ///         stranded ETH to the caller of the sweep, so there is no address
    ///         in this contract that collects anything.
    function sweepToken(DripVaultV2 vault) external {
        IERC20Minimal token = IERC20Minimal(address(vault.token()));
        uint256 bal = token.balanceOf(address(this));
        if (bal > 0) require(token.transfer(vault.devRecipient(), bal), "sweep");
    }

    /// Only the PoolManager refunds ETH here, mid-swap.
    receive() external payable {}
}
