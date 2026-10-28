# CrewBuy

Tiered group buying on BOT Chain.

A seller posts a deal as a price ladder: the more people join, the lower the
price for everyone. Buyers pay the **top** price up front and are refunded down
to whatever tier the crew actually reached.

Paying top and refunding down is what makes this work without trusting anyone.
Nobody has to guess the final price at the moment they join, the seller can
never collect more than the tier reached, and the buyer who joined first gets
exactly the same price as the one who joined last.

## The ladder

`createDeal(item, tierMins[], tierPrices[], durationSecs, cap)` — head counts
strictly ascending, prices strictly descending, up to 8 tiers. `tierMins[0]`
doubles as the minimum for the deal to go ahead at all: finish below it and the
deal **fails**, every buyer takes back the whole of what they paid, and the
seller gets nothing.

| Call | Who | What it does |
|---|---|---|
| `join(id)` | anyone but the seller | Pays exactly the top price, once per address |
| `settle(id)` | **anyone** | Once the clock runs out, or the moment the cap fills |
| `claimRefund(id)` | buyers | Top price minus the tier reached — or everything, if the deal failed or was pulled |
| `sellerWithdraw(id)` | seller | Tier price × head count, minus `feeBps` (2% default, capped 5%) |
| `cancelDeal(id)` | seller | Only before anyone has joined |
| `priceNow`, `nextTier`, `getTiers` | view | What the price is, and what the next drop costs in bodies |

A pause blocks new deals and new joins but never a refund or a payout.
`withdrawFees` is bounded by `accumulatedFees` and cannot touch buyer money.

## Build and deploy

```bash
npm install
npx hardhat test          # 16 tests
npm run deploy:testnet    # BOT Chain testnet, chain 968
npm run deploy:mainnet    # BOT Chain mainnet, chain 677
```

Create `.env` from `.env.example` with your `PRIVATE_KEY` first. The deploy
script prints the network name **and** the chain id.

After deploying, paste the address into `CONTRACT_ADDRESS` in
`frontend/index.html`. For mainnet also swap the five network values flagged in
the comment block directly above it, and set `label` to `"MAINNET"`.

## Frontend

Single file, no build step, ethers v6 from cdnjs. **Neo-brutalism**: thick black
outlines, zero-blur hard offset shadows, unrounded geometry and clashing
saturated accents on a faint graph-paper ground. A sticky slab bar, a split hero,
a full-width ladder builder, then deals in a column-flow masonry. Each deal draws
its ladder as filling bars — one rung per tier, green once the crew clears it.

The page ends with the BOT Chain ecosystem footer, carrying links to
**botchain.ai** and the **block explorer**. The explorer href is read from the
`NETWORK` config at the top of the file, so the five-value mainnet swap updates
it too. No chain ID is printed anywhere on the page — these sites move from
testnet to mainnet, so a rendered chain ID would be wrong half the time.
