const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const DAY = 86400;
const E = (n) => ethers.parseEther(String(n));

describe("CrewBuy", function () {
  let cb, owner, seller, a, b, c, d;

  beforeEach(async () => {
    [owner, seller, a, b, c, d] = await ethers.getSigners();
    const F = await ethers.getContractFactory("CrewBuy");
    cb = await F.deploy();
    await cb.waitForDeployment();
  });

  // 1+ buyers: 1 BOT · 3+: 0.8 · 5+: 0.6
  const MINS = [1, 3, 5];
  const PRICES = [E(1), E("0.8"), E("0.6")];

  async function newDeal(mins = MINS, prices = PRICES, dur = 7 * DAY, cap = 10) {
    await cb.connect(seller).createDeal("Screenprinted deck, 8.25", mins, prices, dur, cap);
    return (await cb.dealCount()) - 1n;
  }

  it("creates a deal from a price ladder", async () => {
    const id = await newDeal();
    const deal = await cb.getDeal(id);
    expect(deal.seller).to.equal(seller.address);
    expect(deal.topPrice).to.equal(E(1));
    expect(deal.cap).to.equal(10);
    const tiers = await cb.getTiers(id);
    expect(tiers.mins.map(Number)).to.deep.equal(MINS);
  });

  it("rejects a ladder that does not fall", async () => {
    await expect(cb.connect(seller).createDeal("x", [1, 3], [E(1)], 7 * DAY, 10)).to.be.revertedWith(
      "length mismatch"
    );
    await expect(
      cb.connect(seller).createDeal("x", [3, 1], [E(1), E("0.8")], 7 * DAY, 10)
    ).to.be.revertedWith("tiers not ascending");
    await expect(
      cb.connect(seller).createDeal("x", [1, 3], [E("0.8"), E(1)], 7 * DAY, 10)
    ).to.be.revertedWith("prices not descending");
    await expect(cb.connect(seller).createDeal("x", [5], [E(1)], 7 * DAY, 3)).to.be.revertedWith(
      "cap below first tier"
    );
  });

  it("takes the top price from everyone, once each", async () => {
    const id = await newDeal();
    await expect(cb.connect(a).join(id, { value: E("0.8") })).to.be.revertedWith("pay the top price");
    await cb.connect(a).join(id, { value: E(1) });
    await expect(cb.connect(a).join(id, { value: E(1) })).to.be.revertedWith("already joined");
    await expect(cb.connect(seller).join(id, { value: E(1) })).to.be.revertedWith("seller cannot join");
    expect((await cb.getDeal(id)).buyers).to.equal(1);
    expect(await cb.lockedTotal()).to.equal(E(1));
  });

  it("drops the price as the crew grows", async () => {
    const id = await newDeal();
    await cb.connect(a).join(id, { value: E(1) });
    expect(await cb.priceNow(id)).to.equal(E(1));
    await cb.connect(b).join(id, { value: E(1) });
    await cb.connect(c).join(id, { value: E(1) });
    expect(await cb.priceNow(id)).to.equal(E("0.8"));

    const next = await cb.nextTier(id);
    expect(next.atBuyers).to.equal(5);
    expect(next.price).to.equal(E("0.6"));
  });

  it("refunds everyone down to the tier the crew reached", async () => {
    const id = await newDeal();
    for (const s of [a, b, c]) await cb.connect(s).join(id, { value: E(1) });

    await time.increase(8 * DAY);
    await cb.connect(d).settle(id); // permissionless
    expect((await cb.getDeal(id)).finalPrice).to.equal(E("0.8"));

    // Everyone paid 1, the tier reached was 0.8, so everyone takes 0.2 back.
    await expect(cb.connect(a).claimRefund(id)).to.changeEtherBalance(a, E("0.2"));
    await expect(cb.connect(b).claimRefund(id)).to.changeEtherBalance(b, E("0.2"));
    await expect(cb.connect(a).claimRefund(id)).to.be.revertedWith("already refunded");
    await expect(cb.connect(d).claimRefund(id)).to.be.revertedWith("not a buyer");
  });

  it("gives the last joiner exactly the price the first joiner gets", async () => {
    const id = await newDeal();
    for (const s of [a, b, c, d, owner]) await cb.connect(s).join(id, { value: E(1) });
    await time.increase(8 * DAY);
    await cb.connect(a).settle(id);
    expect((await cb.getDeal(id)).finalPrice).to.equal(E("0.6"));
    await expect(cb.connect(a).claimRefund(id)).to.changeEtherBalance(a, E("0.4"));
    await expect(cb.connect(owner).claimRefund(id)).to.changeEtherBalance(owner, E("0.4"));
  });

  it("fails the deal and refunds in full below the first tier", async () => {
    const id = await newDeal([3, 5], [E(1), E("0.8")], 7 * DAY, 10);
    await cb.connect(a).join(id, { value: E(1) });
    await cb.connect(b).join(id, { value: E(1) });

    await time.increase(8 * DAY);
    await cb.connect(a).settle(id);
    expect((await cb.getDeal(id)).failed).to.equal(true);

    await expect(cb.connect(a).claimRefund(id)).to.changeEtherBalance(a, E(1));
    await expect(cb.connect(seller).sellerWithdraw(id)).to.be.revertedWith("deal failed");
  });

  it("pays the seller the tier price times the head count, minus the fee", async () => {
    const id = await newDeal();
    for (const s of [a, b, c]) await cb.connect(s).join(id, { value: E(1) });
    await time.increase(8 * DAY);
    await cb.connect(a).settle(id);

    // 3 × 0.8 = 2.4, fee 2% = 0.048
    await expect(cb.connect(a).sellerWithdraw(id)).to.be.revertedWith("not seller");
    await expect(cb.connect(seller).sellerWithdraw(id)).to.changeEtherBalance(seller, E("2.352"));
    await expect(cb.connect(seller).sellerWithdraw(id)).to.be.revertedWith("already paid");
    expect(await cb.accumulatedFees()).to.equal(E("0.048"));
  });

  it("settles as soon as the cap fills, without waiting for the clock", async () => {
    const id = await newDeal(MINS, PRICES, 30 * DAY, 3);
    await cb.connect(a).join(id, { value: E(1) });
    await expect(cb.connect(a).settle(id)).to.be.revertedWith("still running");
    await cb.connect(b).join(id, { value: E(1) });
    await cb.connect(c).join(id, { value: E(1) });

    await expect(cb.connect(d).join(id, { value: E(1) })).to.be.revertedWith("deal full");
    await cb.connect(d).settle(id);
    expect((await cb.getDeal(id)).finalPrice).to.equal(E("0.8"));
  });

  it("refuses a refund when the crew only reached the top tier", async () => {
    const id = await newDeal();
    await cb.connect(a).join(id, { value: E(1) });
    await time.increase(8 * DAY);
    await cb.connect(a).settle(id);
    expect((await cb.getDeal(id)).finalPrice).to.equal(E(1));
    await expect(cb.connect(a).claimRefund(id)).to.be.revertedWith("nothing to refund");
  });

  it("lets the seller pull a deal nobody joined, and refunds if one is cancelled", async () => {
    const id = await newDeal();
    await cb.connect(seller).cancelDeal(id);
    await expect(cb.connect(a).join(id, { value: E(1) })).to.be.revertedWith("cancelled");

    const id2 = await newDeal();
    await cb.connect(a).join(id2, { value: E(1) });
    await expect(cb.connect(seller).cancelDeal(id2)).to.be.revertedWith("buyers already joined");
  });

  it("closes to new buyers once the clock runs out", async () => {
    const id = await newDeal();
    await time.increase(8 * DAY);
    await expect(cb.connect(a).join(id, { value: E(1) })).to.be.revertedWith("deal closed");
  });

  it("refuses to settle twice", async () => {
    const id = await newDeal();
    await cb.connect(a).join(id, { value: E(1) });
    await time.increase(8 * DAY);
    await cb.connect(a).settle(id);
    await expect(cb.connect(a).settle(id)).to.be.revertedWith("already settled");
  });

  it("pauses new deals and joining, but never a refund or a payout", async () => {
    const id = await newDeal();
    for (const s of [a, b, c]) await cb.connect(s).join(id, { value: E(1) });
    await time.increase(8 * DAY);
    await cb.connect(a).settle(id);
    await cb.connect(owner).pause();

    await expect(cb.connect(d).join(id, { value: E(1) })).to.be.revertedWithCustomError(cb, "EnforcedPause");
    await expect(
      cb.connect(seller).createDeal("x", MINS, PRICES, 7 * DAY, 10)
    ).to.be.revertedWithCustomError(cb, "EnforcedPause");
    await cb.connect(a).claimRefund(id);
    await cb.connect(seller).sellerWithdraw(id);
  });

  it("caps the fee and withdraws only fees, leaving the contract square", async () => {
    await expect(cb.connect(owner).setFeeBps(900)).to.be.revertedWith("fee too high");

    const id = await newDeal();
    for (const s of [a, b, c]) await cb.connect(s).join(id, { value: E(1) });
    await time.increase(8 * DAY);
    await cb.connect(a).settle(id);
    for (const s of [a, b, c]) await cb.connect(s).claimRefund(id);
    await cb.connect(seller).sellerWithdraw(id);

    await expect(cb.connect(a).withdrawFees(a.address)).to.be.revertedWithCustomError(
      cb,
      "OwnableUnauthorizedAccount"
    );
    await expect(cb.connect(owner).withdrawFees(owner.address)).to.changeEtherBalance(owner, E("0.048"));
    expect(await cb.lockedTotal()).to.equal(0);
    expect(await ethers.provider.getBalance(await cb.getAddress())).to.equal(0);
  });

  it("lists buyers and deals newest first", async () => {
    const id = await newDeal();
    await cb.connect(a).join(id, { value: E(1) });
    await cb.connect(b).join(id, { value: E(1) });
    expect(await cb.getBuyers(id)).to.deep.equal([a.address, b.address]);
    await newDeal();
    expect((await cb.getRecent(2)).map(Number)).to.deep.equal([1, 0]);
    expect((await cb.getDealsBySeller(seller.address)).length).to.equal(2);
  });
});
