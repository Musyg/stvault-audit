// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal Chainlink AggregatorV3 surface used for collateral pricing.
interface IPriceFeed {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    function decimals() external view returns (uint8);
}

/// @title  StVault - collateralized borrowing vault (DEMONSTRATION CONTRACT)
/// @notice Users deposit a volatile collateral token and borrow a stable asset
///         against it, up to a fixed loan-to-value ratio. Collateral is priced
///         in USD through a Chainlink-style price feed.
/// @dev    Sample target prepared for a security-review demonstration.
///         NOT audited, NOT for production use.
contract StVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateralToken; // volatile asset, 18 decimals (e.g. WETH)
    IERC20 public immutable borrowToken;     // stable asset, 18 decimals (~1 USD)
    IPriceFeed public priceFeed;             // collateral/USD feed (8 decimals)

    uint256 public constant LTV_BPS = 7_500;    // 75% maximum loan-to-value
    uint256 public constant BPS_DENOM = 10_000;
    uint256 public borrowFeeBps = 50;           // 0.5% origination fee

    mapping(address => uint256) public collateralOf; // collateral token units
    mapping(address => uint256) public debtOf;       // borrow token units (principal + fees)

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 fee);
    event Repaid(address indexed user, uint256 amount);

    constructor(IERC20 _collateral, IERC20 _borrow, IPriceFeed _feed) Ownable(msg.sender) {
        collateralToken = _collateral;
        borrowToken = _borrow;
        priceFeed = _feed;
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setPriceFeed(IPriceFeed _feed) external onlyOwner {
        priceFeed = _feed;
    }

    function setBorrowFee(uint256 _bps) external onlyOwner {
        require(_bps <= 500, "fee too high");
        borrowFeeBps = _bps;
    }

    /// @notice Liquidity provisioning for the borrow asset (owner-funded).
    function fund(uint256 amount) external onlyOwner {
        borrowToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    // ---------------------------------------------------------------------
    // User actions
    // ---------------------------------------------------------------------

    function depositCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        collateralOf[msg.sender] += amount;
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralDeposited(msg.sender, amount);
    }

    /// @notice Withdraw the caller's entire collateral. Only callable when debt-free.
    function withdrawCollateral() external {
        require(debtOf[msg.sender] == 0, "outstanding debt");
        uint256 amount = collateralOf[msg.sender];
        require(amount > 0, "no collateral");
        collateralToken.safeTransfer(msg.sender, amount);
        collateralOf[msg.sender] = 0;
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function borrow(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        uint256 fee = (amount / BPS_DENOM) * borrowFeeBps;
        debtOf[msg.sender] += amount + fee;
        require(_healthy(msg.sender), "exceeds max LTV");
        borrowToken.safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount, fee);
    }

    function repay(uint256 amount) external nonReentrant {
        uint256 d = debtOf[msg.sender];
        uint256 pay = amount > d ? d : amount;
        debtOf[msg.sender] = d - pay;
        borrowToken.safeTransferFrom(msg.sender, address(this), pay);
        emit Repaid(msg.sender, pay);
    }

    // ---------------------------------------------------------------------
    // Pricing / health
    // ---------------------------------------------------------------------

    /// @notice USD value (scaled to 1e18) of a user's collateral.
    function collateralValueUsd(address user) public view returns (uint256) {
        (, int256 answer, , , ) = priceFeed.latestRoundData();
        return (collateralOf[user] * uint256(answer)) / 1e8;
    }

    /// @notice Maximum borrowable amount (borrow-token units) for a user.
    function maxBorrow(address user) public view returns (uint256) {
        return (collateralValueUsd(user) * LTV_BPS) / BPS_DENOM;
    }

    function _healthy(address user) internal view returns (bool) {
        return debtOf[user] <= maxBorrow(user);
    }
}
