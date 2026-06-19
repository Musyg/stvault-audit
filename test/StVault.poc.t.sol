// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StVault, IPriceFeed} from "../src/StVault.sol";

// ---------------------------------------------------------------------------
// Mocks (identical to the master/PoC branch - only the assertions change)
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

/// @dev Attacker contract that tries to re-enter withdrawCollateral via the hook.
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
            vault.withdrawCollateral(); // attempt re-entry before zeroing
        }
    }
}

// ---------------------------------------------------------------------------
// Remediation suite - proves each finding is fixed on the `fixed` branch.
// Same scenarios as the PoC branch; the attacks must now fail.
// ---------------------------------------------------------------------------

contract StVaultFixed is Test {
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

    // [H-01 fixed] The 14-day-old price that used to drain the pool is rejected.
    function test_H01_StalePrice_NowRejected() public {
        address mallory = makeAddr("mallory");
        _depositFor(mallory, 10e18);

        // Same stale $2000 answer, 14 days old.
        feed.set(2000e8, block.timestamp - 14 days);

        // Pricing now reverts on staleness instead of trusting the old answer.
        vm.expectRevert(bytes("stale price"));
        vault.maxBorrow(mallory);

        // Borrowing on the stale price is therefore impossible.
        vm.prank(mallory);
        vm.expectRevert(bytes("stale price"));
        vault.borrow(14_900e18);

        // Pool untouched, no debt created.
        assertEq(stable.balanceOf(address(vault)), 100_000e18, "pool intact");
        assertEq(vault.debtOf(mallory), 0, "no debt created");

        // A fresh answer restores normal pricing.
        feed.set(2000e8, block.timestamp);
        assertEq(vault.maxBorrow(mallory), 15_000e18, "fresh price prices collateral correctly");
    }

    // [M-01 fixed] The hook re-entry now reverts; nothing is drained.
    function test_M01_Reentrancy_NowBlocked() public {
        address victim = makeAddr("victim");
        _depositFor(victim, 10e18);

        ReentrancyAttacker attacker = new ReentrancyAttacker(vault, collateral);
        collateral.mint(address(attacker), 10e18);
        attacker.deposit(10e18);

        assertEq(collateral.balanceOf(address(vault)), 20e18, "vault holds both deposits");

        // nonReentrant + CEI: the re-entrant call reverts and the whole tx rolls back.
        vm.expectRevert();
        attacker.attack();

        assertEq(collateral.balanceOf(address(vault)), 20e18, "nothing drained");
        assertEq(collateral.balanceOf(address(attacker)), 0, "attacker got nothing");
        assertEq(vault.collateralOf(address(attacker)), 10e18, "attacker accounting intact");
    }

    // [L-01 fixed] Fee is computed exactly (mulDiv, round up) - no under-charge.
    function test_L01_Fee_NowExact() public {
        address user = makeAddr("user");
        _depositFor(user, 100e18);
        feed.set(2000e8, block.timestamp);

        uint256 amount = 2e18 + 9_999; // the non-round amount that used to truncate
        vm.prank(user);
        vault.borrow(amount);

        uint256 chargedFee = vault.debtOf(user) - amount;
        uint256 expectedFee = Math.mulDiv(amount, vault.borrowFeeBps(), 10_000, Math.Rounding.Ceil);
        assertEq(chargedFee, expectedFee, "fee charged exactly (no truncation)");

        // Strictly more than the old division-before-multiplication result.
        uint256 oldBuggyFee = (amount / 10_000) * vault.borrowFeeBps();
        assertGt(chargedFee, oldBuggyFee, "no longer under-charged");

        emit log_named_uint("charged fee (wei)", chargedFee);
        emit log_named_uint("old buggy fee (wei)", oldBuggyFee);
    }

    // [Control] Fresh, correct price still bounds the borrow at max LTV.
    function test_Control_FreshOracle_StillBounds() public {
        address user = makeAddr("user");
        _depositFor(user, 10e18);

        feed.set(100e8, block.timestamp); // true price, fresh
        assertEq(vault.maxBorrow(user), 750e18);

        vm.prank(user);
        vm.expectRevert(bytes("exceeds max LTV"));
        vault.borrow(15_000e18);
    }
}
