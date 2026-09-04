# PumpPill Hooks

On-chain launch protection for Robinhood Chain (chainId 4663), built on Uniswap v4.
Live, source-verified, ownerless. Docs for buyers and launchers: [pumppill.org/hooks](https://www.pumppill.org/hooks).

| Contract | Address (RH 4663) | What it does |
|---|---|---|
| `SniperRebateHook` | [`0x2166221791aEe01c88F9d8f8552E31f3266d5044`](https://robinhoodchain.blockscout.com/address/0x2166221791aEe01c88F9d8f8552E31f3266d5044) | Declining early-sell tax that pays the opening buyers who held |
| `DripVaultFactory` | [`0xCb518EacEda056F329DB95b3aB8065732260850d`](https://robinhoodchain.blockscout.com/address/0xCb518EacEda056F329DB95b3aB8065732260850d) | Creator-allocation escrow with a pool-aware, rate-limited drip |

Both are immutable: no owner, no upgrades, no pause switch. The only mutable slot in
either contract is the hook's fee `treasury`, rotatable exclusively by itself.

## SniperRebateHook

A Uniswap v4 hook (address flags `0x1044`: `afterInitialize | afterSwap | afterSwapReturnDelta`).

- During a protection window after pool initialization (default 6h), every sell pays a
  tax declining linearly from 25% to 0, collected in the swap's **unspecified** currency
  (the quote side for standard exact-in sells) via the afterSwap fee pattern.
- 90% fills a per-pool pot; buyers from the opening window (default 30min) who held
  through protection claim it pro-rata. A hard-coded 10% (`PROTOCOL_FEE_BIPS`) accrues
  to the treasury, **pull-claimed** via `claimProtocolFees()` — nothing on the swap path
  ever pushes to an external address, so a reverting treasury cannot brick a pool.
- Rebates unclaimed 30 days after the window sweep to the treasury.
- After the window the hook is provably inert: 0 extra fee, forever.
- Per-pool tuning: the pool creator (`tx.origin` at initialize) may set tax/windows
  within hard caps (30% / 24h) until trading starts. ETH/WETH-quoted pools
  auto-configure; any other quote (stock- or token-quoted pairs) activates via a
  one-time `configure()` declaring the token side.
- Every pool ever initialized against the hook is enumerable on-chain (`allPools`).

Taxing **all** early sells — rather than trying to flag "snipers" — is deliberate: it is
the only shape that survives fresh-wallet evasion. The honest cost (early honest sellers
pay a declining rate) is disclosed, and it reaches zero within hours.

### Launching against the hook

```solidity
PoolKey({
  currency0: Currency.wrap(address(0)),       // native ETH (or your quote, sorted)
  currency1: Currency.wrap(yourToken),
  fee: 3000,
  tickSpacing: 60,
  hooks: IHooks(0x2166221791aEe01c88F9d8f8552E31f3266d5044)
})
```

Initialize via the PoolManager (`0x8366a39CC670B4001A1121B8F6A443A643e40951`), add
liquidity, done — ETH/WETH pairs protect automatically. Optionally call
`configure(poolId, tokenIsZero, taxBips, protectionSeconds, trackWindowSeconds)`
before the first trade to tune within caps or to declare the token side of a
non-ETH-quoted pair.

## DripVault

Deliberately **not** a swap hook: swap-level enforcement of "the dev can't sell fast"
is evaded by a wallet transfer, so the design inverts it — the allocation sits in the
vault, and whatever isn't escrowed is visibly un-escrowed.

- Per 24h epoch the vault releases at most
  `min(dripBips × allocation, depthBips × currentPoolDepth)` after an optional cliff.
  Depth is the token-side amount within a ±20% price band at the pool's active
  liquidity, read live from the PoolManager (`getSlot0` + `getLiquidity` +
  `SqrtPriceMath`) — releases throttle automatically when liquidity is thin.
- Releases only ever reach the `devRecipient` fixed at creation. No admin functions.
- One escape hatch: 30 consecutive days of zero pool liquidity (an abandoned launch)
  unlocks the remainder — observable on-chain the whole time.
- Vaults can also be created unbound (pure time schedule) for non-v4 pools.
- The factory keeps an enumerable registry (`vaultsByToken`, `allVaults`).

## First live usage (2026-09-03)

Smoke-test launch exercising every mechanism with real value:

- Token `PPTEST` [`0x999d307093eD09243BD0Bd947217A78aECc38f3F`](https://robinhoodchain.blockscout.com/address/0x999d307093eD09243BD0Bd947217A78aECc38f3F)
- Pool `0xa07bfefcf33b7666cdceda29a27f06d4931f28e9a6487787b6a46f55b4c72281` — initialize
  [`0x148b…ca83`](https://robinhoodchain.blockscout.com/tx/0x148b6c680f053cbdb6b697e3dbd22c508ae036e67fe30534f2c6694149ebca83),
  tracked buy
  [`0x65e9…fb41`](https://robinhoodchain.blockscout.com/tx/0x65e9bd481ccd2764494233d9815781af1f7e17658996c398ca8bed417e0fbb41),
  taxed sell
  [`0x5799…f401`](https://robinhoodchain.blockscout.com/tx/0x5799b924d5c984f5d5461d9eda50c977a3ba8b42b340b9bb232f39022356f401)
- Vault [`0x8D87002DDdaB0eE03A493Ce01df29b8D5bFc0A79`](https://robinhoodchain.blockscout.com/address/0x8D87002DDdaB0eE03A493Ce01df29b8D5bFc0A79)
  escrowing 100M PPTEST — created
  [`0x79b8…2249`](https://robinhoodchain.blockscout.com/tx/0x79b8039d77503eb66fcad502a0f249cf06bd83f277b1af228cbe216e29972249)

## Build & test

```bash
git clone --depth 1 --recurse-submodules --shallow-submodules \
  https://github.com/Uniswap/v4-periphery lib/v4-periphery

forge build
forge test --no-match-path "test/Fork.t.sol"   # 40 unit/fuzz tests
forge test --match-path "test/Fork.t.sol"      # mainnet-fork rehearsal (needs RPC)
```

The fork test deploys through the real CREATE2 proxy and runs the full
buy → tax → claim → protocol-fee cycle against Robinhood Chain's live PoolManager.

## Known limitations (v1, documented on purpose)

- Buyer attribution uses `tx.origin`: EIP-7702-delegated EOAs attribute correctly;
  ERC-4337 bundler flows credit the bundler's EOA.
- The hook cannot see plain token transfers; a buyer can transfer tokens out and still
  claim — approximately net-neutral, since the receiving wallet's sell pays the tax.
- A creator can escrow only part of their supply; consumers of the vault registry
  should report the escrowed share, not a binary badge (our scanner does).
- Not independently audited. Source is verified and the test suite is public.

## License

MIT — see [LICENSE](LICENSE).
