// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title CrewBuy
 * @notice Tiered group buying on BOT Chain.
 *
 * A seller posts a deal as a price ladder: the more people join, the lower the
 * price for everyone. Buyers pay the **top** price up front and are refunded
 * down to whatever tier the crew actually reached.
 *
 * Paying top and refunding down is what makes this work without trusting
 * anyone. Nobody has to guess the final price at the moment they join, the
 * seller can never collect more than the tier reached, and a buyer who joined
 * first gets exactly the same price as the one who joined last.
 *
 * If the crew never reaches the first tier's minimum, the deal fails and every
 * buyer takes back the whole of what they paid. The seller gets nothing.
 */
contract CrewBuy is Ownable, Pausable, ReentrancyGuard {
    struct Deal {
        address seller;
        uint64 endsAt;
        uint32 cap;
        uint32 buyers;
        uint256 topPrice;
        uint256 finalPrice;
        bool settled;
        bool failed;
        bool sellerPaid;
        bool cancelled;
        string item;
    }

    uint64 public constant MIN_DURATION = 1 hours;
    uint64 public constant MAX_DURATION = 90 days;
    uint256 public constant MAX_ITEM = 72;
    uint256 public constant MAX_TIERS = 8;
    uint16 public constant MAX_FEE_BPS = 500;

    /// @notice Taken from the seller's proceeds at withdrawal.
    uint16 public feeBps = 200;

    uint256 public accumulatedFees;
    /// @notice Buyer money not yet refunded or paid out.
    uint256 public lockedTotal;

    Deal[] private _deals;
    mapping(uint256 => uint32[]) private _tierMin;
    mapping(uint256 => uint256[]) private _tierPrice;
    mapping(uint256 => mapping(address => bool)) private _bought;
    mapping(uint256 => mapping(address => bool)) private _refunded;
    mapping(uint256 => address[]) private _buyers;
    mapping(address => uint256[]) private _dealsBySeller;

    event DealCreated(uint256 indexed id, address indexed seller, string item, uint256 topPrice, uint32 cap, uint64 endsAt);
    event Joined(uint256 indexed id, address indexed buyer, uint32 buyers, uint256 priceNow);
    event DealSettled(uint256 indexed id, address indexed settler, uint256 finalPrice, uint32 buyers, bool failed);
    event Refunded(uint256 indexed id, address indexed buyer, uint256 amount);
    event SellerPaid(uint256 indexed id, address indexed seller, uint256 amount, uint256 fee);
    event DealCancelled(uint256 indexed id);
    event FeeUpdated(uint16 feeBps);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {}

    // --------------------------------------------------------------- deals

    /**
     * @param tierMins Buyer counts at which each price takes effect, strictly
     *        ascending. `tierMins[0]` doubles as the minimum for the deal to
     *        go ahead at all.
     * @param tierPrices Prices for each tier, strictly descending.
     */
    function createDeal(
        string calldata item,
        uint32[] calldata tierMins,
        uint256[] calldata tierPrices,
        uint64 durationSecs,
        uint32 cap
    ) external whenNotPaused returns (uint256 id) {
        require(bytes(item).length > 0 && bytes(item).length <= MAX_ITEM, "bad item");
        require(tierMins.length == tierPrices.length, "length mismatch");
        require(tierMins.length > 0 && tierMins.length <= MAX_TIERS, "bad tier count");
        require(durationSecs >= MIN_DURATION && durationSecs <= MAX_DURATION, "bad duration");
        require(tierMins[0] >= 1, "first tier below one");
        require(cap >= tierMins[0], "cap below first tier");
        require(tierPrices[0] > 0, "top price zero");

        for (uint256 i = 1; i < tierMins.length; i++) {
            require(tierMins[i] > tierMins[i - 1], "tiers not ascending");
            require(tierPrices[i] < tierPrices[i - 1], "prices not descending");
        }

        id = _deals.length;
        _deals.push(
            Deal({
                seller: msg.sender,
                endsAt: uint64(block.timestamp) + durationSecs,
                cap: cap,
                buyers: 0,
                topPrice: tierPrices[0],
                finalPrice: 0,
                settled: false,
                failed: false,
                sellerPaid: false,
                cancelled: false,
                item: item
            })
        );
        for (uint256 i = 0; i < tierMins.length; i++) {
            _tierMin[id].push(tierMins[i]);
            _tierPrice[id].push(tierPrices[i]);
        }
        _dealsBySeller[msg.sender].push(id);
        emit DealCreated(id, msg.sender, item, tierPrices[0], cap, _deals[id].endsAt);
    }

    function join(uint256 id) external payable whenNotPaused {
        Deal storage d = _deal(id);
        require(!d.cancelled, "cancelled");
        require(!d.settled, "settled");
        require(block.timestamp < d.endsAt, "deal closed");
        require(d.buyers < d.cap, "deal full");
        require(msg.sender != d.seller, "seller cannot join");
        require(!_bought[id][msg.sender], "already joined");
        require(msg.value == d.topPrice, "pay the top price");

        _bought[id][msg.sender] = true;
        _buyers[id].push(msg.sender);
        unchecked {
            d.buyers += 1;
        }
        lockedTotal += msg.value;
        emit Joined(id, msg.sender, d.buyers, priceAt(id, d.buyers));
    }

    /**
     * @notice Fix the final price. Anyone may call it once the deal ends, or
     *         as soon as the cap is full — there is nothing left to wait for.
     */
    function settle(uint256 id) external {
        Deal storage d = _deal(id);
        require(!d.cancelled, "cancelled");
        require(!d.settled, "already settled");
        require(block.timestamp >= d.endsAt || d.buyers == d.cap, "still running");

        d.settled = true;
        if (d.buyers < _tierMin[id][0]) {
            d.failed = true;
            d.finalPrice = 0;
        } else {
            d.finalPrice = priceAt(id, d.buyers);
        }
        emit DealSettled(id, msg.sender, d.finalPrice, d.buyers, d.failed);
    }

    /// @notice Take back the difference between the top price and the tier reached.
    function claimRefund(uint256 id) external nonReentrant {
        Deal storage d = _deal(id);
        require(d.settled || d.cancelled, "not settled");
        require(_bought[id][msg.sender], "not a buyer");
        require(!_refunded[id][msg.sender], "already refunded");

        uint256 amount = (d.failed || d.cancelled) ? d.topPrice : d.topPrice - d.finalPrice;
        require(amount > 0, "nothing to refund");

        _refunded[id][msg.sender] = true;
        lockedTotal -= amount;
        emit Refunded(id, msg.sender, amount);

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "refund failed");
    }

    function sellerWithdraw(uint256 id) external nonReentrant {
        Deal storage d = _deal(id);
        require(d.seller == msg.sender, "not seller");
        require(d.settled, "not settled");
        require(!d.failed, "deal failed");
        require(!d.sellerPaid, "already paid");

        uint256 gross = d.finalPrice * d.buyers;
        require(gross > 0, "nothing to collect");

        d.sellerPaid = true;
        uint256 fee = (gross * feeBps) / 10_000;
        accumulatedFees += fee;
        lockedTotal -= gross;

        emit SellerPaid(id, msg.sender, gross - fee, fee);
        (bool ok, ) = payable(msg.sender).call{value: gross - fee}("");
        require(ok, "payout failed");
    }

    /// @notice Pull a deal before anybody has joined it.
    function cancelDeal(uint256 id) external {
        Deal storage d = _deal(id);
        require(d.seller == msg.sender, "not seller");
        require(!d.settled && !d.cancelled, "closed");
        require(d.buyers == 0, "buyers already joined");
        d.cancelled = true;
        emit DealCancelled(id);
    }

    // --------------------------------------------------------------- views

    /// @notice The price the ladder reaches at a given head count.
    function priceAt(uint256 id, uint32 buyers) public view returns (uint256) {
        uint32[] storage mins = _tierMin[id];
        uint256[] storage prices = _tierPrice[id];
        uint256 price = prices[0];
        for (uint256 i = 0; i < mins.length; i++) {
            if (buyers >= mins[i]) price = prices[i];
        }
        return price;
    }

    /// @notice What the price would be if the deal settled right now.
    function priceNow(uint256 id) external view returns (uint256) {
        Deal storage d = _deal(id);
        if (d.settled) return d.finalPrice;
        if (d.buyers < _tierMin[id][0]) return d.topPrice;
        return priceAt(id, d.buyers);
    }

    /// @notice Head count needed for the next price drop, and that price. Zero when none is left.
    function nextTier(uint256 id) external view returns (uint32 atBuyers, uint256 price) {
        Deal storage d = _deal(id);
        uint32[] storage mins = _tierMin[id];
        for (uint256 i = 0; i < mins.length; i++) {
            if (d.buyers < mins[i]) return (mins[i], _tierPrice[id][i]);
        }
        return (0, 0);
    }

    function dealCount() external view returns (uint256) {
        return _deals.length;
    }

    function getDeal(uint256 id) external view returns (Deal memory) {
        return _deal(id);
    }

    function getTiers(uint256 id) external view returns (uint32[] memory mins, uint256[] memory prices) {
        return (_tierMin[id], _tierPrice[id]);
    }

    function getBuyers(uint256 id) external view returns (address[] memory) {
        return _buyers[id];
    }

    function hasJoined(uint256 id, address who) external view returns (bool) {
        return _bought[id][who];
    }

    function hasRefunded(uint256 id, address who) external view returns (bool) {
        return _refunded[id][who];
    }

    function getDealsBySeller(address seller) external view returns (uint256[] memory) {
        return _dealsBySeller[seller];
    }

    /// @notice Newest-first page of deal ids.
    function getRecent(uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _deals.length;
        if (limit > n) limit = n;
        ids = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = n - 1 - i;
        }
    }

    // --------------------------------------------------------------- admin

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Bounded by `accumulatedFees`. Buyer money is unreachable from here.
    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "bad recipient");
        uint256 amount = accumulatedFees;
        require(amount > 0, "nothing to withdraw");
        accumulatedFees = 0;
        emit FeesWithdrawn(to, amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // ------------------------------------------------------------ internal

    function _deal(uint256 id) private view returns (Deal storage) {
        require(id < _deals.length, "no such deal");
        return _deals[id];
    }

    receive() external payable {
        accumulatedFees += msg.value;
    }
}
