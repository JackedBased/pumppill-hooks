# PumpPill Hooks

On-chain launch protection for Robinhood Chain (chainId 4663), built on Uniswap v4.
Live, source-verified, ownerless. Docs for buyers and launchers: [pumppill.org/hooks](https://www.pumppill.org/hooks).

| Contract | Address (RH 4663) | What it does |
|---|---|---|
| `SniperRebateHook` | [`0x2166221791aEe01c88F9d8f8552E31f3266d5044`](https://robinhoodchain.blockscout.com/address/0x2166221791aEe01c88F9d8f8552E31f3266d5044) | Declining early-sell tax that pays the opening buyers who held |
| `DripVaultFactory` | [`0xCb518EacEda056F329DB95b3aB8065732260850d`](https://robinhoodchain.blockscout.com/address/0xCb518EacEda056F329DB95b3aB8065732260850d) | Creator-allocation escrow with a pool-aware, rate-limited drip |
| `DripVaultV2Factory` | [`0xA5fE802B0515B6793EdF291eA4E4BB71fd77E0b3`](https://repo.sourcify.dev/4663/0xA5fE802B0515B6793EdF291eA4E4BB71fd77E0b3/) | Same, with per-deposit cliffs and a restricted depositor |
| `BuyAndEscrowRouter` | [`0xc734b12AAF8aDAf9ff92a7eC24E9214146b8CD32`](https://repo.sourcify.dev/4663/0xc734b12AAF8aDAf9ff92a7eC24E9214146b8CD32/) | Buys a creator's bag and escrows it in one transaction |

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

## DripVaultV2 + BuyAndEscrowRouter

Written for a launch flow that puts the **entire fixed supply into the LP position**,
leaving no reserved creator allocation to escrow. If there is no free allocation, the
creator's bag has to be bought like anyone else's — which is a stronger guarantee than a
carve-out, because the bag is paid for, but only if the buy and the lock are the same
transaction. Buying and then choosing whether to lock is a promise; doing both atomically
is a fact.

To be precise about the mechanics: the buy moves the pool along its curve, changing
reserves and price. It does **not** mint liquidity and does not add depth. What it
produces is a paid-for bag that is locked, and that is the entire claim.

### What v2 changes, and why

Two holes in v1, both at the cliff, both harmless when a vault was funded once at launch
and both serious once funding can land at any time:

- v1 measured the cliff from `createdAt` for **every** deposit, so anything deposited
  after the cliff had passed was releasable the same day.
- v1 sized the per-epoch cap off **total** allocation, so a late deposit raised the drip
  rate on the bag that was already escrowed — and since v1 deposits were permissionless,
  a third party could do it to someone else's vault.

v2 gives every deposit its own tranche with its own unlock, and makes only matured
tranches visible to the release path: an immature tranche neither pays out nor raises the
cap. Maturity rides a forward-only cursor, so each tranche is walked once in its life
rather than on every call, bounded by a minimum deposit size and a 64-tranche ceiling.

An immutable `depositor` address (normally the router) makes *"every token in here was
bought on the open market"* a property of the contract rather than a claim about the
creator. Set it to `address(0)` to allow a community lock alongside the creator's, at the
cost of the badge meaning exactly one thing.

The dead-pool escape releases immature tranches too. The cliff protects buyers in a live
market; there is no market left to protect after 30 days of zero liquidity, and burning
someone's tokens for launching into a pool that died is not a protection.

### BuyAndEscrowRouter

One transaction that either buys and escrows or does neither.

1. **validate** — token is in the pool, the vault is bound to *this* pool, the vault
   admits this router as its depositor
2. **swap** — through the ordinary path with the pool's hook attached
3. **measure** — `received = balanceAfter - balanceBefore`, on the router itself, not a
   quote and not the swap's reported delta
4. **guard** — revert unless `received >= minEscrowed`
5. **escrow** — approve exactly `received`, deposit, re-assert the vault's allocation
   rose by exactly that, reset the approval to zero
6. **refund** — return any unspent input to the caller

No `try`/`catch` anywhere on the path: a failed escrow takes the buy down with it, so a
creator can never end up holding a free-floating bag because the escrow leg reverted
quietly. Launch guards — anti-snipe caps, opening-window fees — see this buy exactly as
they see any other; the router asks for no exemption and should never be granted one.

The swap carries the **creator** as beneficiary in `hookData`, distinct from the vault
that receives the tokens and from the router that sends the swap. Nothing reads
`tx.origin`.

Feeless on purpose: a fee here would tax the one behaviour the design exists to make
attractive.

### Verification

Both v2 contracts are verified on **Sourcify** ([factory](https://repo.sourcify.dev/4663/0xA5fE802B0515B6793EdF291eA4E4BB71fd77E0b3/),
[router](https://repo.sourcify.dev/4663/0xc734b12AAF8aDAf9ff92a7eC24E9214146b8CD32/)), not on Blockscout, and not by choice: the
per-instance API at `robinhoodchain.blockscout.com` now answers a Cloudflare challenge — which
is how the v1 contracts were verified in early September, and that route has since closed —
while the PRO multichain API is read-only (its verification config 404s, a submission 500s).
Sourcify supports chain 4663 and is what Blockscout's bytecode database imports from, so the
explorer should catch up on its own schedule.

Neither contract has an owner. The keeper that signed the deployment keeps no power over
either one: the factory can only deploy vaults, and the router can only swap and deposit into
a vault that already admits it as its depositor.

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
forge test --no-match-path "test/Fork.t.sol"   # 63 unit/fuzz tests
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
- `DripVault` v1 is live and unchanged, and carries the two cliff holes described in the
  v2 section above. It is left deployed rather than quietly retired because these are
  immutable contracts and someone may be relying on one; v2 is a new deployment, not an
  upgrade. New vaults should use v2.
- Not independently audited. Source is verified and the test suite is public.

## License

MIT — see [LICENSE](LICENSE).
