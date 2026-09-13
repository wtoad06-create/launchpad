// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC20 with fixed total supply, fully minted to the Launchpad
///         at creation time. No further minting is possible.
contract LaunchToken {
    string public name;
    string public symbol;
    uint8  public constant decimals = 18;
    uint256 public immutable totalSupply;
    address public immutable launchpad;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint256 _supply, address _launchpad) {
        name = _name;
        symbol = _symbol;
        totalSupply = _supply;
        launchpad = _launchpad;
        balanceOf[_launchpad] = _supply; // full fixed supply held by the curve at birth
        emit Transfer(address(0), _launchpad, _supply);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "allowance too low");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(balanceOf[from] >= value, "balance too low");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}

/// @title Launchpad
/// @notice Anyone can launch a fixed-supply token. Every token starts life on a
///         linear bonding curve held by this contract: buyers send native coin
///         (ETH/MATIC/etc depending on chain) in, tokens come out, priced by how
///         much of the curve supply has already been sold. Selling reverses it.
///         Once a token's raised reserve crosses GRADUATION_THRESHOLD, trading on
///         the curve is frozen ("graduated") and the remaining reserve + unsold
///         tokens are left for the creator to seed a real DEX pool manually.
contract Launchpad {
    struct TokenInfo {
        address token;
        address creator;
        uint256 curveSupply;     // tokens originally allocated to the curve (out of totalSupply)
        uint256 sold;            // how many curve tokens have been bought so far
        uint256 reserveBalance;  // native coin currently held for this token's curve
        uint256 basePrice;       // price (wei) of the very first token
        uint256 slope;           // price increases by `slope` wei per whole token sold
        bool graduated;
    }

    uint256 public constant GRADUATION_THRESHOLD = 10 ether; // tune per chain/native coin
    uint256 public constant CREATOR_FEE_BPS = 100;           // 1% of every buy/sell goes to creator
    uint256 public constant PROTOCOL_FEE_BPS = 100;          // 1% goes to protocol
    address public protocolFeeRecipient;

    TokenInfo[] public tokens; // index = tokenId
    mapping(address => uint256) public tokenIdOf; // token address -> id+1 (0 = not found)

    event TokenCreated(uint256 indexed tokenId, address indexed token, address indexed creator, string name, string symbol, uint256 totalSupply);
    event Buy(uint256 indexed tokenId, address indexed buyer, uint256 amountTokens, uint256 costWei);
    event Sell(uint256 indexed tokenId, address indexed seller, uint256 amountTokens, uint256 payoutWei);
    event Graduated(uint256 indexed tokenId, uint256 finalReserve);

    constructor(address _protocolFeeRecipient) {
        protocolFeeRecipient = _protocolFeeRecipient;
    }

    /// @param totalSupply full fixed supply of the new token (18 decimals)
    /// @param curveSupply how much of that supply is sold via the bonding curve
    ///        (the rest stays with the creator, e.g. for a team allocation)
    function createToken(
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply,
        uint256 curveSupply,
        uint256 basePrice,
        uint256 slope
    ) external returns (uint256 tokenId, address tokenAddr) {
        require(curveSupply <= totalSupply, "curve supply exceeds total");
        require(totalSupply > 0 && basePrice > 0, "bad params");

        LaunchToken t = new LaunchToken(name_, symbol_, totalSupply, address(this));
        tokenAddr = address(t);

        uint256 creatorAllocation = totalSupply - curveSupply;
        if (creatorAllocation > 0) {
            t.transfer(msg.sender, creatorAllocation);
        }

        tokens.push(TokenInfo({
            token: tokenAddr,
            creator: msg.sender,
            curveSupply: curveSupply,
            sold: 0,
            reserveBalance: 0,
            basePrice: basePrice,
            slope: slope,
            graduated: false
        }));
        tokenId = tokens.length - 1;
        tokenIdOf[tokenAddr] = tokenId + 1;

        emit TokenCreated(tokenId, tokenAddr, msg.sender, name_, symbol_, totalSupply);
    }

    /// @notice price (wei) for the NEXT whole token, given `sold` already sold
    function currentPrice(uint256 tokenId) public view returns (uint256) {
        TokenInfo storage info = tokens[tokenId];
        return info.basePrice + (info.slope * info.sold) / 1e18;
    }

    /// @notice quote the total wei cost to buy `amount` tokens (18-decimals) right now
    function quoteBuy(uint256 tokenId, uint256 amount) public view returns (uint256 cost) {
        TokenInfo storage info = tokens[tokenId];
        require(info.sold + amount <= info.curveSupply, "exceeds curve supply");
        // integrate linear price over the purchased range using the average price
        uint256 startPrice = info.basePrice + (info.slope * info.sold) / 1e18;
        uint256 endPrice = info.basePrice + (info.slope * (info.sold + amount)) / 1e18;
        uint256 avgPrice = (startPrice + endPrice) / 2;
        cost = (avgPrice * amount) / 1e18;
    }

    /// @notice quote the total wei payout for selling `amount` tokens right now
    function quoteSell(uint256 tokenId, uint256 amount) public view returns (uint256 payout) {
        TokenInfo storage info = tokens[tokenId];
        require(amount <= info.sold, "exceeds sold supply");
        uint256 startPrice = info.basePrice + (info.slope * info.sold) / 1e18;
        uint256 endPrice = info.basePrice + (info.slope * (info.sold - amount)) / 1e18;
        uint256 avgPrice = (startPrice + endPrice) / 2;
        payout = (avgPrice * amount) / 1e18;
    }

    function buy(uint256 tokenId, uint256 amount, uint256 maxCostWei) external payable {
        TokenInfo storage info = tokens[tokenId];
        require(!info.graduated, "token graduated, trade on DEX");

        uint256 cost = quoteBuy(tokenId, amount);
        require(cost <= maxCostWei, "slippage exceeded");
        require(msg.value >= cost, "insufficient payment");

        uint256 creatorFee = (cost * CREATOR_FEE_BPS) / 10000;
        uint256 protocolFee = (cost * PROTOCOL_FEE_BPS) / 10000;
        uint256 netReserve = cost - creatorFee - protocolFee;

        info.sold += amount;
        info.reserveBalance += netReserve;

        LaunchToken(info.token).transfer(msg.sender, amount);

        if (creatorFee > 0) payable(info.creator).transfer(creatorFee);
        if (protocolFee > 0) payable(protocolFeeRecipient).transfer(protocolFee);
        if (msg.value > cost) payable(msg.sender).transfer(msg.value - cost); // refund overpayment

        emit Buy(tokenId, msg.sender, amount, cost);

        if (info.reserveBalance >= GRADUATION_THRESHOLD) {
            info.graduated = true;
            emit Graduated(tokenId, info.reserveBalance);
            // Remaining reserve + unsold tokens stay in this contract for the
            // creator to withdraw and seed a real DEX pool (see withdrawGraduated).
        }
    }

    function sell(uint256 tokenId, uint256 amount, uint256 minPayoutWei) external {
        TokenInfo storage info = tokens[tokenId];
        require(!info.graduated, "token graduated, trade on DEX");

        uint256 payout = quoteSell(tokenId, amount);
        require(payout >= minPayoutWei, "slippage exceeded");

        LaunchToken token = LaunchToken(info.token);
        require(token.allowance(msg.sender, address(this)) >= amount, "approve tokens first");
        require(token.balanceOf(msg.sender) >= amount, "insufficient tokens");

        token.transferFrom(msg.sender, address(this), amount);

        info.sold -= amount;
        info.reserveBalance -= payout;

        payable(msg.sender).transfer(payout);
        emit Sell(tokenId, msg.sender, amount, payout);
    }

    /// @notice after graduation, the creator withdraws the raised reserve to
    ///         seed liquidity on a real DEX of their choice
    function withdrawGraduated(uint256 tokenId) external {
        TokenInfo storage info = tokens[tokenId];
        require(info.graduated, "not graduated yet");
        require(msg.sender == info.creator, "only creator");
        uint256 amount = info.reserveBalance;
        info.reserveBalance = 0;
        payable(info.creator).transfer(amount);
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function getToken(uint256 tokenId) external view returns (TokenInfo memory) {
        return tokens[tokenId];
    }
}
