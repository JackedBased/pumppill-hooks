// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {DripVaultV2, IERC20} from "./DripVaultV2.sol";

/// @title DripVaultV2Factory
/// @notice Deploys DripVaultV2s and keeps an enumerable on-chain registry so
///         scanners (and buyers) can discover every vault for a token.
///
/// @dev    The pool is created before the vault, so the poolId is known at
///         construction and is immutable. There is no bind step and therefore
///         no permissionless-bind hole: a vault cannot be pointed at a pool
///         with fabricated depth after the fact, which is the one thing that
///         would quietly disable the depth cap.
///
///         Parameters arrive as a struct rather than a parameter list because
///         the list is stack-too-deep on the legacy pipeline, and via-IR is
///         not available here — it breaks the v4-core Pool library under test.
contract DripVaultV2Factory {
    error TokenNotInPool();
    error ZeroToken();

    event VaultCreated(
        address indexed vault,
        address indexed token,
        address indexed devRecipient,
        address depositor,
        bool poolBound,
        PoolId poolId
    );

    /// @param token        the launched token being escrowed
    /// @param devRecipient the only address escrowed tokens can ever reach
    /// @param depositor    the only address permitted to deposit. Pass the
    ///        buy-and-escrow router to make "every token in here was bought on
    ///        the open market" a property of the contract. Pass address(0) to
    ///        let anyone deposit, which allows a community lock alongside the
    ///        creator's at the cost of the badge meaning exactly one thing.
    /// @param dripBips     per-epoch release ceiling, in bips of matured allocation
    /// @param depthBips    per-epoch release ceiling, in bips of live pool depth
    /// @param cliffSeconds lock applied to each deposit from its own timestamp
    /// @param minDeposit   floor on a single deposit, so the bounded tranche
    ///        array cannot be filled with dust
    struct NewVault {
        address token;
        address devRecipient;
        address depositor;
        uint16 dripBips;
        uint16 depthBips;
        uint32 cliffSeconds;
        uint256 minDeposit;
    }

    IPoolManager public immutable poolManager;

    address[] public allVaults;
    mapping(address => address[]) internal _vaultsByToken;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Create a vault bound to a v4 pool: the drip is capped by both
    ///         the time schedule and current pool depth.
    function createVault(PoolKey calldata key, NewVault calldata p) external returns (DripVaultV2 vault) {
        if (p.token == address(0)) revert ZeroToken();
        bool tokenIsZero;
        if (Currency.unwrap(key.currency0) == p.token) tokenIsZero = true;
        else if (Currency.unwrap(key.currency1) != p.token) revert TokenNotInPool();

        vault = new DripVaultV2(
            DripVaultV2.VaultConfig({
                token: IERC20(p.token),
                devRecipient: p.devRecipient,
                depositor: p.depositor,
                dripBips: p.dripBips,
                depthBips: p.depthBips,
                cliffSeconds: p.cliffSeconds,
                minDeposit: p.minDeposit,
                poolBound: true,
                tokenIsZero: tokenIsZero,
                poolManager: poolManager,
                poolId: key.toId()
            })
        );
        _register(address(vault), p, true, key.toId());
    }

    /// @notice Create an unbound vault (pure time-schedule drip). Works with
    ///         any pool type — v2/v3/v4/launchpad curves — at the cost of the
    ///         depth cap, which has nothing to read. `depthBips` is ignored.
    function createUnboundVault(NewVault calldata p) external returns (DripVaultV2 vault) {
        if (p.token == address(0)) revert ZeroToken();
        vault = new DripVaultV2(
            DripVaultV2.VaultConfig({
                token: IERC20(p.token),
                devRecipient: p.devRecipient,
                depositor: p.depositor,
                dripBips: p.dripBips,
                depthBips: 0,
                cliffSeconds: p.cliffSeconds,
                minDeposit: p.minDeposit,
                poolBound: false,
                tokenIsZero: false,
                poolManager: poolManager,
                poolId: PoolId.wrap(0)
            })
        );
        _register(address(vault), p, false, PoolId.wrap(0));
    }

    function _register(address vault, NewVault calldata p, bool poolBound, PoolId poolId) internal {
        allVaults.push(vault);
        _vaultsByToken[p.token].push(vault);
        emit VaultCreated(vault, p.token, p.devRecipient, p.depositor, poolBound, poolId);
    }

    // ----------------------------------------------------------- registry

    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    function vaultsByToken(address token) external view returns (address[] memory) {
        return _vaultsByToken[token];
    }
}
