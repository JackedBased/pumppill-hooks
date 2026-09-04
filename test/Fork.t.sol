// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Mainnet-fork rehearsal against the REAL Robinhood Chain Uniswap v4 stack.
// Needs network access to rpc.mainnet.chain.robinhood.com:
//   forge test --match-path test/Fork.t.sol -vv
// Validates: CREATE2-proxy hook deploy at a mined flag address, pool init on
// the real PoolManager, tax/claim cycle, and DripVault depth reads — i.e.
// everything the mainnet deploy will do, except spending real gas.

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "../lib/v4-periphery/test/shared/HookMiner.sol";
import {SniperRebateHook} from "../src/SniperRebateHook.sol";
import {DripVault} from "../src/DripVault.sol";
import {DripVaultFactory} from "../src/DripVaultFactory.sol";

contract ForkTest is Test {
    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant AEWETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // production parameters — keep in sync with the deploy script
    address constant TREASURY = 0x75e7c0E3698bA64c3385A12ce8e573854511B7ff;
    uint32 constant START_TAX = 2_500;
    uint32 constant PROTECTION = 6 hours;
    uint32 constant TRACK_WINDOW = 30 minutes;
    uint256 constant CLAIM_WINDOW = 30 days;

    SniperRebateHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    MockERC20 token;
    PoolKey key;
    PoolId id;
    uint256 t0;

    address alice = makeAddr("alice");
    address sniper = makeAddr("sniper");
    address dev = makeAddr("dev");

    function setUp() public {
        vm.createSelectFork("robinhood");

        // ---- deploy the hook exactly as mainnet will: real CREATE2 proxy ----
        bytes memory args =
            abi.encode(MANAGER, AEWETH, TREASURY, START_TAX, PROTECTION, TRACK_WINDOW, CLAIM_WINDOW);
        uint160 flags =
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_PROXY, flags, type(SniperRebateHook).creationCode, args);
        (bool ok,) = CREATE2_PROXY.call(abi.encodePacked(salt, type(SniperRebateHook).creationCode, args));
        require(ok, "create2 deploy failed");
        require(predicted.code.length > 0, "no code at predicted address");
        hook = SniperRebateHook(payable(predicted));
        emit log_named_address("hook (mined)", predicted);
        emit log_named_bytes32("salt", salt);

        swapRouter = new PoolSwapTest(MANAGER);
        lpRouter = new PoolModifyLiquidityTest(MANAGER);

        token = new MockERC20("PumpPill Fork Test", "PPTEST", 18);
        token.mint(address(this), 1e27);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(predicted)
        });
        vm.prank(address(this), address(this)); // tx.origin = creator
        MANAGER.initialize(key, SQRT_PRICE_1_1);
        id = key.toId();
        t0 = block.timestamp;

        vm.deal(address(this), 300 ether);
        lpRouter.modifyLiquidity{value: 101 ether}(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 100e18, salt: 0}),
            ""
        );
    }

    receive() external payable {}

    function _buy(address origin, uint256 ethIn) internal returns (uint256 out) {
        uint256 before = token.balanceOf(address(this));
        vm.prank(address(this), origin);
        swapRouter.swap{value: ethIn}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        out = token.balanceOf(address(this)) - before;
    }

    function _sell(address origin, uint256 tokensIn) internal returns (uint256 ethOut) {
        uint256 before = address(this).balance;
        vm.prank(address(this), origin);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokensIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        ethOut = address(this).balance - before;
    }

    /// the full launch story on real chain state: buys tracked, sniper taxed
    /// in ETH, holder claims 90%, treasury pulls its 10%
    function test_fork_full_cycle() public {
        uint256 aliceOut = _buy(alice, 0.01 ether);
        assertEq(hook.netBought(id, alice), aliceOut);

        uint256 snipeOut = _buy(sniper, 0.02 ether);
        vm.warp(t0 + 1 hours);
        _sell(sniper, snipeOut);
        assertEq(hook.netBought(id, sniper), 0);
        uint256 pot = hook.pools(id).potQuote;
        uint256 proto = hook.protocolFees(CurrencyLibrary.ADDRESS_ZERO);
        assertGt(pot, 0); // sniper paid ETH into the pot
        assertGt(proto, 0); // 10% accrued to protocol
        assertApproxEqAbs(proto * 9, pot, 9); // exact 90/10 split

        vm.warp(t0 + PROTECTION + 1);
        assertEq(hook.currentTaxBips(id), 0);

        vm.prank(alice);
        hook.claim(id);
        assertEq(alice.balance, pot); // sole eligible holder takes the pot

        uint256 treasuryBefore = TREASURY.balance;
        hook.claimProtocolFees(CurrencyLibrary.ADDRESS_ZERO);
        assertEq(TREASURY.balance - treasuryBefore, proto); // fees reach 0x75e7…B7ff
    }

    /// DripVault reads depth from the REAL PoolManager
    function test_fork_dripvault() public {
        DripVaultFactory factory = new DripVaultFactory(MANAGER);
        DripVault vault = factory.createVault(key, address(token), dev, 100, 100, uint32(7 days));
        token.approve(address(vault), type(uint256).max);
        vault.deposit(100_000_000e18);

        assertGt(vault.poolDepth(), 0);
        assertEq(vault.releasable(), 0); // cliff
        vm.warp(t0 + 7 days);
        uint256 r = vault.releasable();
        assertGt(r, 0);
        vault.release(r);
        assertEq(token.balanceOf(dev), r);
    }
}
