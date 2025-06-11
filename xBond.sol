// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// OpenZeppelin Imports
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// PulseX Router Interface
interface IPulseXRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/**
 * @title PulseStrategy
 * @notice A Decentralized PLSX Reserve, allowing minting/redeeming of xBond that is redeemable for PLSX.
 * @dev xBond has a 4.5% tax on transfers. (excluding redemptions)
 */
contract PulseStrategy is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --------------------------------------
    // Errors
    // --------------------------------------
    error InvalidAmount();
    error InsufficientBalance();
    error ZeroAddress();
    error IssuancePeriodEnded();
    error InsufficientContractBalance();
    error InsufficientAllowance();
    error SwapFailed();
    error PairNotSet();

    // --------------------------------------
    // Events
    // --------------------------------------
    event SharesIssued(address indexed buyer, uint256 shares, uint256 totalFee);
    event SharesRedeemed(address indexed redeemer, uint256 shares, uint256 plsx);
    event TransferTaxApplied(address indexed from, address indexed to, uint256 amountAfterTax, uint256 xBondToController, uint256 plsxReceived);
    event PairAddressSet(address indexed pair);
    event TokensBurned(address indexed caller, uint256 amount);

    // --------------------------------------
    // State Variables
    // --------------------------------------
    address private _pairAddress;
    uint256 private _totalSupplyMinted;
    uint48 private _deploymentTime;

    // --------------------------------------
    // Immutable Variables
    // --------------------------------------
    address private immutable _pulseXRouter = 0x165C3410fC91EF562C50559f7d2289fEbed552d9;
    address private immutable _plsx = 0x95B303987A60C71504D99Aa1b13B4DA07b0790ab;
    address private immutable _strategyController;

    // --------------------------------------
    // Constants
    // --------------------------------------
    uint16 private constant _FEE_BASIS_POINTS = 450; // 4.5%
    uint256 private constant _MIN_LIQUIDITY = 10e18; // 10 PLSX
    uint256 private constant _MIN_TRANSFER = 1e18; // 1 xBond
    uint256 private constant _MIN_FEE = 1e16; // 0.01 xBond or PLSX
    uint8 private constant _MIN_OUTPUT_PERCENT = 90; // 90%
    uint16 private constant _BASIS_DENOMINATOR = 10000; // 10,000
    uint256 private constant _ISSUANCE_PERIOD = 180 days; // ~6 months
    uint256 private constant _SWAP_DEADLINE = 5 minutes; // 300 seconds

    // --------------------------------------
    // Constructor
    // --------------------------------------
    constructor() ERC20("PulseStrategy", "xBond") {
        if (_pulseXRouter == address(0) || _plsx == address(0)) revert ZeroAddress();
        _strategyController = msg.sender;
        _deploymentTime = uint48(block.timestamp);
    }

    // --------------------------------------
    // Internal Helper
    // --------------------------------------
    function _calculateFee(uint256 amount) private pure returns (uint256) {
        return (amount * _FEE_BASIS_POINTS) / _BASIS_DENOMINATOR;
    }

    // --------------------------------------
    // Pair Management
    // --------------------------------------
    function setPairAddress(address pair) external {
        if (msg.sender != _strategyController || pair == address(0)) revert ZeroAddress();
        _pairAddress = pair;
        emit PairAddressSet(pair);
    }

    // --------------------------------------
    // Swap Functionality
    // --------------------------------------
    function _swapToPLSX(uint256 xBondAmount) private returns (uint256 plsxReceived) {
        if (xBondAmount == 0) return 0;
        address pair = _pairAddress;
        if (pair == address(0)) revert PairNotSet();

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _plsx;

        uint256 amountOutMin = (xBondAmount * 9971) / 10000;
        uint256 reserveIn = IERC20(address(this)).balanceOf(pair);
        uint256 reserveOut = IERC20(_plsx).balanceOf(pair);
        if (reserveIn > 0 && reserveOut > 0) {
            amountOutMin = (amountOutMin * reserveOut) / (reserveIn * 10000 + amountOutMin);
            amountOutMin = (amountOutMin * _MIN_OUTPUT_PERCENT) / 100;
        }

        uint256 allowance = IERC20(address(this)).allowance(address(this), _pulseXRouter);
        if (allowance < xBondAmount) {
            SafeERC20.safeIncreaseAllowance(IERC20(address(this)), _pulseXRouter, xBondAmount - allowance);
        }

        uint256 balanceBefore = IERC20(_plsx).balanceOf(address(this));
        IPulseXRouter(_pulseXRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            xBondAmount,
            amountOutMin,
            path,
            address(this),
            block.timestamp + _SWAP_DEADLINE
        );

        plsxReceived = IERC20(_plsx).balanceOf(address(this)) - balanceBefore;
        if (plsxReceived == 0) revert SwapFailed();
        return plsxReceived;
    }

    // --------------------------------------
    // Burn Functionality
    // --------------------------------------
    function burnContractxBond() external nonReentrant {
        uint256 xBondAmount = balanceOf(address(this));
        if (xBondAmount == 0) revert InvalidAmount();
        _burn(address(this), xBondAmount);
        emit TokensBurned(msg.sender, xBondAmount);
    }

    // --------------------------------------
    // Transfer and Tax Logic
    // --------------------------------------
    function _applyTransferTax(address from, address to, uint256 amount) private {
        if (amount < _MIN_TRANSFER) revert InvalidAmount();
        if (balanceOf(from) < amount) revert InsufficientBalance();

        if (from == _strategyController || to == _strategyController || from == address(this) || to == address(this)) {
            _transfer(from, to, amount);
            emit TransferTaxApplied(from, to, amount, 0, 0);
            return;
        }

        uint256 fee = _calculateFee(amount);
        if (fee < _MIN_FEE) {
            _transfer(from, to, amount);
            emit TransferTaxApplied(from, to, amount, 0, 0);
            return;
        }

        uint256 burnShare = (fee * 2) / 10; // 20%
        uint256 controllerShare = fee / 20; // 5%
        uint256 swapShare = fee - burnShare - controllerShare; // 75%
        uint256 amountAfterTax = amount - fee;

        uint256 plsxReceived = 0;
        if (swapShare > 0 && _pairAddress != address(0)) {
            _transfer(from, address(this), swapShare);
            plsxReceived = _swapToPLSX(swapShare);
            emit TransferTaxApplied(from, to, amountAfterTax, controllerShare, plsxReceived);
        } else {
            if (swapShare > 0) _transfer(from, address(this), swapShare);
            emit TransferTaxApplied(from, to, amountAfterTax, controllerShare, 0);
        }

        if (burnShare > 0) _burn(from, burnShare);
        if (controllerShare > 0) _transfer(from, _strategyController, controllerShare);
        _transfer(from, to, amountAfterTax);
    }

    function transfer(address to, uint256 amount) public override nonReentrant returns (bool) {
        _applyTransferTax(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override nonReentrant returns (bool) {
        uint256 allowed = allowance(from, msg.sender);
        if (allowed < amount) revert InsufficientAllowance();
        _applyTransferTax(from, to, amount);
        if (allowed != type(uint256).max) {
            _approve(from, msg.sender, allowed - amount);
        }
        return true;
    }

    // --------------------------------------
    // Share Issuance and Redemption
    // --------------------------------------
    function issueShares(uint256 plsxAmount) external nonReentrant {
        if (plsxAmount < _MIN_LIQUIDITY || block.timestamp > _deploymentTime + _ISSUANCE_PERIOD)
            revert IssuancePeriodEnded();
        if (IERC20(_plsx).allowance(msg.sender, address(this)) < plsxAmount) revert InsufficientAllowance();

        IERC20(_plsx).safeTransferFrom(msg.sender, address(this), plsxAmount);
        uint256 fee = _calculateFee(plsxAmount);
        if (fee < _MIN_FEE) revert InvalidAmount();

        uint256 shares = plsxAmount - fee;
        uint256 feeToContract = fee / 2;
        uint256 feeToController = fee - feeToContract;
        uint256 sharesToController = feeToController;

        if (feeToController > 0) IERC20(_plsx).safeTransfer(_strategyController, feeToController);
        _mint(msg.sender, shares);
        _totalSupplyMinted += shares;
        if (sharesToController > 0) {
            _mint(_strategyController, sharesToController);
            _totalSupplyMinted += sharesToController;
        }
        emit SharesIssued(msg.sender, shares, fee);
    }

    function redeemShares(uint256 shareAmount) external nonReentrant {
        if (shareAmount == 0 || balanceOf(msg.sender) < shareAmount) revert InvalidAmount();
        uint256 contractTotalSupply = totalSupply();
        if (contractTotalSupply == 0) revert InsufficientContractBalance();
        uint256 plsxAmount = (IERC20(_plsx).balanceOf(address(this)) * shareAmount) / contractTotalSupply;
        if (plsxAmount == 0) revert InsufficientContractBalance();

        _burn(msg.sender, shareAmount);
        IERC20(_plsx).safeTransfer(msg.sender, plsxAmount);
        emit SharesRedeemed(msg.sender, shareAmount, plsxAmount);
    }

    // --------------------------------------
    // View Functions
    // --------------------------------------
    function getContractMetrics() external view returns (
        uint256 contractTotalSupply,
        uint256 plsxBalance,
        uint256 totalMinted,
        uint256 totalBurned,
        uint256 plsxBackingRatio
    ) {
        contractTotalSupply = totalSupply();
        plsxBalance = IERC20(_plsx).balanceOf(address(this));
        totalMinted = _totalSupplyMinted;
        totalBurned = _totalSupplyMinted - contractTotalSupply;
        plsxBackingRatio = contractTotalSupply == 0 ? 0 : (plsxBalance * 1e18) / contractTotalSupply;
    }

    function getIssuanceStatus() external view returns (bool isActive, uint256 timeRemaining) {
        isActive = block.timestamp <= _deploymentTime + _ISSUANCE_PERIOD;
        timeRemaining = isActive ? _deploymentTime + _ISSUANCE_PERIOD - block.timestamp : 0;
    }
}