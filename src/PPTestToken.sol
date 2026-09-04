// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Guinea-pig token for the SniperRebateHook v2 + DripVault live
///         exercise (2026-09-03). 1B fixed supply to the deployer; no mint,
///         no owner, nothing else. Not a product.
contract PPTestToken is ERC20 {
    constructor() ERC20("PumpPill Hook Test", "PPTEST", 18) {
        _mint(msg.sender, 1_000_000_000e18);
    }
}
