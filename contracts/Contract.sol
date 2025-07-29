// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Uniswap V2 Router interface
interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    
    function getAmountsOut(uint amountIn, address[] calldata path) 
        external view returns (uint[] memory amounts);
}

// Uniswap V3 Router interface - FIXED
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);

    function exactInput(ExactInputParams calldata params)
        external payable returns (uint256 amountOut);
}

// Uniswap V3 Quoter interface
interface IQuoterV2 {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);

    function quoteExactInput(bytes memory path, uint256 amountIn)
        external returns (uint256 amountOut);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/**
 * @title abokiv2contract
 * @dev A contract that allows users to create crypto exchange orders
 * and processes them through Uniswap V2/V3 aggregators with flexible routing
 */
contract AbokiV2Contract is Ownable, ReentrancyGuard {
    // Enums
    enum SwapVersion { V2, V3 }
    
    // State variables
    uint256 public orderIdCounter;
    IUniswapV2Router02 public uniswapV2Router;
    ISwapRouter public uniswapV3Router;
    IQuoterV2 public uniswapV3Quoter;
    address public WETH;
    
    // Common fee tiers for Uniswap V3
    uint24 public constant FEE_LOW = 500;      // 0.05%
    uint24 public constant FEE_MEDIUM = 3000;  // 0.3%
    uint24 public constant FEE_HIGH = 10000;   // 1%
    
    // Mapping to track supported tokens
    mapping(address => bool) public supportedTokens;
    
    // Order struct to store order information
    struct Order {
        address token;
        uint256 amount;
        uint256 rate;
        address creator;
        address refundAddress;
        address liquidityProvider;
        address feeRecipient;
        uint256 feePercent;
        bool isFulfilled;
        bool isRefunded;
        uint256 timestamp;
    }
    
    // Swap parameters for V3
    struct SwapParamsV3 {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    
    // Mapping to store orders by ID
    mapping(uint256 => Order) public orders;
    
    // Events
    event OrderCreated(
        uint256 orderId, 
        address token, 
        uint256 amount, 
        uint256 rate, 
        address refundAddress, 
        address liquidityProvider,
        address feeRecipient,
        uint256 feePercent
    );
    event OrderFulfilled(uint256 orderId, address liquidityProvider);
    event OrderRefunded(uint256 orderId);
    event TokenSupportUpdated(address token, bool isSupported);
    event V2RouterUpdated(address uniswapV2Router);
    event V3RouterUpdated(address uniswapV3Router);
    event V3QuoterUpdated(address uniswapV3Quoter);
    event WETHUpdated(address weth);
    event SwapExecuted(
        address fromToken, 
        address toToken, 
        uint256 amountIn, 
        uint256 amountOut, 
        SwapVersion version
    );
    
    // Receive function to handle ETH transfers
    receive() external payable {}
    
    constructor(address _initialOwner) Ownable() {
        require(_initialOwner != address(0), "Invalid initial owner");
        transferOwnership(_initialOwner);
    }
    
    /**
     * @dev Sets the Uniswap V2 Router address
     * @param _router The address of the Uniswap V2 Router
     */
    function setUniswapV2Router(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router address");
        uniswapV2Router = IUniswapV2Router02(_router);
        emit V2RouterUpdated(_router);
    }
    
    /**
     * @dev Sets the Uniswap V3 Router address
     * @param _router The address of the Uniswap V3 Router
     */
    function setUniswapV3Router(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router address");
        uniswapV3Router = ISwapRouter(_router);
        emit V3RouterUpdated(_router);
    }
    
    /**
     * @dev Sets the Uniswap V3 Quoter address
     * @param _quoter The address of the Uniswap V3 Quoter
     */
    function setUniswapV3Quoter(address _quoter) external onlyOwner {
        require(_quoter != address(0), "Invalid quoter address");
        uniswapV3Quoter = IQuoterV2(_quoter);
        emit V3QuoterUpdated(_quoter);
    }
    
    /**
     * @dev Sets the WETH address
     * @param _weth The address of the Wrapped ETH contract
     */
    function setWETH(address _weth) external onlyOwner {
        require(_weth != address(0), "Invalid WETH address");
        WETH = _weth;
        emit WETHUpdated(_weth);
    }
    
    /**
     * @dev Sets token support status
     * @param _token The token address
     * @param _isSupported Whether the token is supported
     */
    function setTokenSupport(address _token, bool _isSupported) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        supportedTokens[_token] = _isSupported;
        emit TokenSupportUpdated(_token, _isSupported);
    }
    
    /**
     * @dev Creates a new exchange order with supported tokens
     * @param _token The token address
     * @param _amount The amount of tokens
     * @param _rate The expected exchange rate
     * @param _refundAddress The address to refund tokens if needed
     * @param _liquidityProvider The address of the liquidity provider
     * @param _feeRecipient The address to receive protocol fees
     * @param _feePercent The fee percentage in basis points
     * @return orderId The ID of the created order
     */
    function createOrder(
        address _token,
        uint256 _amount,
        uint256 _rate,
        address _refundAddress,
        address _liquidityProvider,
        address _feeRecipient,
        uint256 _feePercent
    ) external nonReentrant returns (uint256 orderId) {
        require(supportedTokens[_token], "Token not supported");
        require(_amount > 0, "Amount must be greater than 0");
        require(_rate > 0, "Rate must be greater than 0");
        require(_refundAddress != address(0), "Invalid refund address");
        require(_liquidityProvider != address(0), "Invalid liquidity provider address");
        require(_feeRecipient != address(0), "Invalid fee recipient address");
        require(_feePercent <= 1000, "Fee too high"); // Max 10%
        
        // Transfer tokens from user to contract
        IERC20 token = IERC20(_token);
        require(token.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        // Calculate protocol fee
        uint256 feeAmount = (_amount * _feePercent) / 10000;
        uint256 netAmount = _amount - feeAmount;
        
        // Transfer fee to fee recipient and tokens to liquidity provider
        if (feeAmount > 0) {
            require(token.transfer(_feeRecipient, feeAmount), "Fee transfer failed");
        }
        require(token.transfer(_liquidityProvider, netAmount), "Liquidity provider transfer failed");
        
        // Create order
        orderId = orderIdCounter++;
        orders[orderId] = Order({
            token: _token,
            amount: _amount,
            rate: _rate,
            creator: msg.sender,
            refundAddress: _refundAddress,
            liquidityProvider: _liquidityProvider,
            feeRecipient: _feeRecipient,
            feePercent: _feePercent,
            isFulfilled: true, // Auto-fulfilled
            isRefunded: false,
            timestamp: block.timestamp
        });
        
        emit OrderCreated(orderId, _token, _amount, _rate, _refundAddress, _liquidityProvider, _feeRecipient, _feePercent);
        emit OrderFulfilled(orderId, _liquidityProvider);
    }
    
    /**
     * @dev Creates a new exchange order by swapping ETH to target token using V2
     * @param _targetToken The supported token to swap to
     * @param _minOutputAmount The minimum amount of target tokens expected
     * @param _rate The expected exchange rate for the created order
     * @param _refundAddress The address to refund tokens if needed
     * @param _liquidityProvider The address of the liquidity provider
     * @param _feeRecipient The address to receive protocol fees
     * @param _feePercent The fee percentage in basis points
     * @return orderId The ID of the created order
     */
    function createOrderWithETHSwapV2(
        address _targetToken,
        uint256 _minOutputAmount,
        uint256 _rate,
        address _refundAddress,
        address _liquidityProvider,
        address _feeRecipient,
        uint256 _feePercent
    ) external payable nonReentrant returns (uint256 orderId) {
        require(msg.value > 0, "ETH required");
        require(_minOutputAmount > 0, "Min output amount must be greater than 0");
        require(supportedTokens[_targetToken], "Target token not supported");
        require(_refundAddress != address(0), "Invalid refund address");
        require(_liquidityProvider != address(0), "Invalid liquidity provider");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_feePercent <= 1000, "Fee too high");
        require(address(uniswapV2Router) != address(0), "Uniswap V2 router not set");
        require(WETH != address(0), "WETH address not set");

        uint256 inputAmount = msg.value;
        uint256 outputAmount = _executeETHToTokenSwapV2(_targetToken, inputAmount, _minOutputAmount, _refundAddress);
        
        orderId = _createOrderAfterSwap(
            _targetToken,
            outputAmount,
            _rate,
            _refundAddress,
            _liquidityProvider,
            _feeRecipient,
            _feePercent
        );
    }
    
    /**
     * @dev Creates a new exchange order by swapping ETH to target token using V3 - FIXED
     * @param _targetToken The supported token to swap to
     * @param _fee The fee tier for the V3 pool
     * @param _minOutputAmount The minimum amount of target tokens expected
     * @param _rate The expected exchange rate for the created order
     * @param _refundAddress The address to refund tokens if needed
     * @param _liquidityProvider The address of the liquidity provider
     * @param _feeRecipient The address to receive protocol fees
     * @param _feePercent The fee percentage in basis points
     * @return orderId The ID of the created order
     */
    function createOrderWithETHSwapV3(
        address _targetToken,
        uint24 _fee,
        uint256 _minOutputAmount,
        uint256 _rate,
        address _refundAddress,
        address _liquidityProvider,
        address _feeRecipient,
        uint256 _feePercent
    ) external payable nonReentrant returns (uint256 orderId) {
        require(msg.value > 0, "ETH required");
        require(_minOutputAmount > 0, "Min output amount must be greater than 0");
        require(supportedTokens[_targetToken], "Target token not supported");
        require(_refundAddress != address(0), "Invalid refund address");
        require(_liquidityProvider != address(0), "Invalid liquidity provider");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_feePercent <= 1000, "Fee too high");
        require(address(uniswapV3Router) != address(0), "Uniswap V3 router not set");
        require(WETH != address(0), "WETH address not set");

        uint256 inputAmount = msg.value;
        uint256 outputAmount = _executeETHToTokenSwapV3(_targetToken, _fee, inputAmount, _minOutputAmount, _refundAddress);
        
        orderId = _createOrderAfterSwap(
            _targetToken,
            outputAmount,
            _rate,
            _refundAddress,
            _liquidityProvider,
            _feeRecipient,
            _feePercent
        );
    }
    
    /**
     * @dev Creates a new exchange order by swapping tokens using V2 with custom path
     * @param _path Array of token addresses representing the swap path
     * @param _inputAmount The amount of input tokens
     * @param _minOutputAmount The minimum amount of target tokens expected
     * @param _rate The expected exchange rate for the created order
     * @param _refundAddress The address to refund tokens if needed
     * @param _liquidityProvider The address of the liquidity provider
     * @param _feeRecipient The address to receive protocol fees
     * @param _feePercent The fee percentage in basis points
     * @return orderId The ID of the created order
     */
    function createOrderWithTokenSwapV2(
        address[] calldata _path,
        uint256 _inputAmount,
        uint256 _minOutputAmount,
        uint256 _rate,
        address _refundAddress,
        address _liquidityProvider,
        address _feeRecipient,
        uint256 _feePercent
    ) external nonReentrant returns (uint256 orderId) {
        require(address(uniswapV2Router) != address(0), "Uniswap V2 router not set");
        require(_path.length >= 2, "Path too short");
        require(_inputAmount > 0, "Input amount must be greater than 0");
        require(_minOutputAmount > 0, "Min output amount must be greater than 0");
        require(supportedTokens[_path[_path.length - 1]], "Target token not supported");
        require(_refundAddress != address(0), "Invalid refund address");
        require(_liquidityProvider != address(0), "Invalid liquidity provider address");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_feePercent <= 1000, "Fee too high");
        
        uint256 outputAmount = _executeTokenSwapV2(_path, _inputAmount, _minOutputAmount);
        
        orderId = _createOrderAfterSwap(
            _path[_path.length - 1],
            outputAmount,
            _rate,
            _refundAddress,
            _liquidityProvider,
            _feeRecipient,
            _feePercent
        );
    }
    
    /**
     * @dev Creates a new exchange order by swapping tokens using V3 with encoded path - FIXED
     * @param _path The encoded path for V3 swap
     * @param _tokenIn The input token address
     * @param _tokenOut The output token address
     * @param _inputAmount The amount of input tokens
     * @param _minOutputAmount The minimum amount of target tokens expected
     * @param _rate The expected exchange rate for the created order
     * @param _refundAddress The address to refund tokens if needed
     * @param _liquidityProvider The address of the liquidity provider
     * @param _feeRecipient The address to receive protocol fees
     * @param _feePercent The fee percentage in basis points
     * @return orderId The ID of the created order
     */
    function createOrderWithTokenSwapV3(
        bytes calldata _path,
        address _tokenIn,
        address _tokenOut,
        uint256 _inputAmount,
        uint256 _minOutputAmount,
        uint256 _rate,
        address _refundAddress,
        address _liquidityProvider,
        address _feeRecipient,
        uint256 _feePercent
    ) external nonReentrant returns (uint256 orderId) {
        require(address(uniswapV3Router) != address(0), "Uniswap V3 router not set");
        require(_inputAmount > 0, "Input amount must be greater than 0");
        require(_minOutputAmount > 0, "Min output amount must be greater than 0");
        require(supportedTokens[_tokenOut], "Target token not supported");
        require(_refundAddress != address(0), "Invalid refund address");
        require(_liquidityProvider != address(0), "Invalid liquidity provider address");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_feePercent <= 1000, "Fee too high");
        
        uint256 outputAmount = _executeTokenSwapV3(_path, _tokenIn, _inputAmount, _minOutputAmount);
        
        orderId = _createOrderAfterSwap(
            _tokenOut,
            outputAmount,
            _rate,
            _refundAddress,
            _liquidityProvider,
            _feeRecipient,
            _feePercent
        );
    }
    
    /**
     * @dev Internal function to execute ETH to token swap using V2
     */
    function _executeETHToTokenSwapV2(
        address _targetToken,
        uint256 _inputAmount,
        uint256 _minOutputAmount,
        address _refundAddress
    ) internal returns (uint256 outputAmount) {
        // Wrap ETH to WETH
        IWETH(WETH).deposit{value: _inputAmount}();
        IERC20(WETH).approve(address(uniswapV2Router), _inputAmount);

        // Create path array
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = _targetToken;

        try uniswapV2Router.swapExactTokensForTokens(
            _inputAmount,
            _minOutputAmount,
            path,
            address(this),
            block.timestamp + 300
        ) returns (uint[] memory amounts) {
            outputAmount = amounts[amounts.length - 1];
            emit SwapExecuted(WETH, _targetToken, _inputAmount, outputAmount, SwapVersion.V2);
        } catch {
            // Unwrap WETH back to ETH and refund
            IWETH(WETH).withdraw(_inputAmount);
            (bool success, ) = _refundAddress.call{value: _inputAmount}("");
            require(success, "ETH refund failed");
            revert("V2 swap failed");
        }
    }
    
    /**
     * @dev Internal function to execute ETH to token swap using V3 - FIXED
     * Key fixes:
     * 1. Direct ETH payment to router (no WETH wrapping needed)
     * 2. Proper parameter handling
     * 3. Better error handling
     */
    function _executeETHToTokenSwapV3(
        address _targetToken,
        uint24 _fee,
        uint256 _inputAmount,
        uint256 _minOutputAmount,
        address _refundAddress
    ) internal returns (uint256 outputAmount) {
        
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: _targetToken,
            fee: _fee,
            recipient: address(this),
            amountIn: _inputAmount,
            amountOutMinimum: _minOutputAmount,
            sqrtPriceLimitX96: 0
        });

        try uniswapV3Router.exactInputSingle{value: _inputAmount}(params) returns (uint256 amountOut) {
            outputAmount = amountOut;
            emit SwapExecuted(WETH, _targetToken, _inputAmount, outputAmount, SwapVersion.V3);
        } catch {
            // Refund ETH directly
            (bool success, ) = _refundAddress.call{value: _inputAmount}("");
            require(success, "ETH refund failed");
            revert("V3 swap failed");
        }
    }
    
    /**
     * @dev Internal function to execute token to token swap using V2
     */
    function _executeTokenSwapV2(
        address[] calldata _path,
        uint256 _inputAmount,
        uint256 _minOutputAmount
    ) internal returns (uint256 outputAmount) {
        // Transfer input tokens from user to contract
        IERC20 inputToken = IERC20(_path[0]);
        require(inputToken.transferFrom(msg.sender, address(this), _inputAmount), "Transfer failed");
        
        // Approve router to spend the input tokens
        require(inputToken.approve(address(uniswapV2Router), _inputAmount), "Approval failed");
        
        address targetToken = _path[_path.length - 1];
        
        try uniswapV2Router.swapExactTokensForTokens(
            _inputAmount,
            _minOutputAmount,
            _path,
            address(this),
            block.timestamp + 300
        ) returns (uint[] memory amounts) {
            outputAmount = amounts[amounts.length - 1];
            emit SwapExecuted(_path[0], targetToken, _inputAmount, outputAmount, SwapVersion.V2);
        } catch {
            // Refund the user if the swap fails
            require(inputToken.transfer(msg.sender, _inputAmount), "Refund failed");
            revert("V2 swap failed");
        }
    }
    
    /**
     * @dev Internal function to execute token to token swap using V3 - FIXED
     * Key fixes:
     * 1. Handle ETH/WETH properly in multi-hop swaps
     * 2. Better token transfer and approval logic
     * 3. Check if first token is WETH to handle ETH input
     */
    function _executeTokenSwapV3(
        bytes calldata _path,
        address _tokenIn,
        uint256 _inputAmount,
        uint256 _minOutputAmount
    ) internal returns (uint256 outputAmount) {
        
        // Check if this is an ETH swap by looking at the first token in path
        address firstToken = _extractFirstToken(_path);
        bool isETHInput = (firstToken == WETH && msg.value > 0);
        
        if (isETHInput) {
            // ETH input case - use msg.value
            require(msg.value == _inputAmount, "ETH amount mismatch");
            
            ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
                path: _path,
                recipient: address(this),
                amountIn: _inputAmount,
                amountOutMinimum: _minOutputAmount
            });
            
            try uniswapV3Router.exactInput{value: _inputAmount}(params) returns (uint256 amountOut) {
                outputAmount = amountOut;
                emit SwapExecuted(_tokenIn, address(0), _inputAmount, outputAmount, SwapVersion.V3);
            } catch {
                // Refund ETH
                (bool success, ) = msg.sender.call{value: _inputAmount}("");
                require(success, "ETH refund failed");
                revert("V3 swap failed");
            }
        } else {
            // Regular token input case
            IERC20 inputToken = IERC20(_tokenIn);
            require(inputToken.transferFrom(msg.sender, address(this), _inputAmount), "Transfer failed");
            require(inputToken.approve(address(uniswapV3Router), _inputAmount), "Approval failed");
            
            ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
                path: _path,
                recipient: address(this),
                amountIn: _inputAmount,
                amountOutMinimum: _minOutputAmount
            });
            
            try uniswapV3Router.exactInput(params) returns (uint256 amountOut) {
                outputAmount = amountOut;
                emit SwapExecuted(_tokenIn, address(0), _inputAmount, outputAmount, SwapVersion.V3);
            } catch {
                // Refund tokens
                require(inputToken.transfer(msg.sender, _inputAmount), "Refund failed");
                revert("V3 swap failed");
            }
        }
    }
    
    /**
     * @dev Helper function to extract first token from V3 path - FIXED
     */
    function _extractFirstToken(bytes memory path) internal pure returns (address token) {
        require(path.length >= 20, "Invalid path length");
        assembly {
            token := div(mload(add(path, 32)), 0x1000000000000000000000000)
        }
    }
    
    /**
     * @dev Helper function to extract last token from V3 path - FIXED
     */
    function _extractLastToken(bytes memory path) internal pure returns (address token) {
        require(path.length >= 20, "Invalid path length");
        assembly {
            token := div(mload(add(path, add(12, path))), 0x1000000000000000000000000)
        }
    }
    
    /**
     * @dev Internal function to create order after successful swap
     */
    function _createOrderAfterSwap(
        address _targetToken,
        uint256 _outputAmount,
        uint256 _rate,
        address _refundAddress,
        address _liquidityProvider,
        address _feeRecipient,
        uint256 _feePercent
    ) internal returns (uint256 orderId) {
        // Calculate and deduct fee
        uint256 feeAmount = (_outputAmount * _feePercent) / 10000;
        uint256 netAmount = _outputAmount - feeAmount;

        IERC20 targetToken = IERC20(_targetToken);
        if (feeAmount > 0) {
            require(targetToken.transfer(_feeRecipient, feeAmount), "Fee transfer failed");
        }
        require(targetToken.transfer(_liquidityProvider, netAmount), "LP transfer failed");

        // Store order
        orderId = orderIdCounter++;
        orders[orderId] = Order({
            token: _targetToken,
            amount: _outputAmount,
            rate: _rate,
            creator: msg.sender,
            refundAddress: _refundAddress,
            liquidityProvider: _liquidityProvider,
            feeRecipient: _feeRecipient,
            feePercent: _feePercent,
            isFulfilled: true,
            isRefunded: false,
            timestamp: block.timestamp
        });

        emit OrderCreated(orderId, _targetToken, _outputAmount, _rate, _refundAddress, _liquidityProvider, _feeRecipient, _feePercent);
        emit OrderFulfilled(orderId, _liquidityProvider);
    }
    
    /**
     * @dev Estimates the amount of target tokens for V2 swap
     * @param _inputToken The token to swap from
     * @param _targetToken The token to swap to
     * @param _inputAmount The amount of input tokens
     * @return The estimated amount of target tokens
     */
    function estimateSwapOutputV2(
        address _inputToken,
        address _targetToken,
        uint256 _inputAmount
    ) external view returns (uint256) {
        require(address(uniswapV2Router) != address(0), "Uniswap V2 router not set");
        
        address[] memory path = new address[](2);
        path[0] = _inputToken;
        path[1] = _targetToken;
        
        uint[] memory amounts = uniswapV2Router.getAmountsOut(_inputAmount, path);
        return amounts[1];
    }
    
    /**
     * @dev Estimates the amount of target tokens for V2 swap with custom path
     * @param _path The swap path
     * @param _inputAmount The amount of input tokens
     * @return The estimated amount of target tokens
     */
    function estimateSwapOutputV2WithPath(
        address[] calldata _path,
        uint256 _inputAmount
    ) external view returns (uint256) {
        require(address(uniswapV2Router) != address(0), "Uniswap V2 router not set");
        require(_path.length >= 2, "Path too short");
        
        uint[] memory amounts = uniswapV2Router.getAmountsOut(_inputAmount, _path);
        return amounts[_path.length - 1];
    }
    
    /**
     * @dev Estimates the amount of target tokens for V3 single swap
     * @param _tokenIn The token to swap from
     * @param _tokenOut The token to swap to
     * @param _fee The fee tier
     * @param _inputAmount The amount of input tokens
     * @return The estimated amount of target tokens
     */
    function estimateSwapOutputV3Single(
        address _tokenIn,
        address _tokenOut,
        uint24 _fee,
        uint256 _inputAmount
    ) external returns (uint256) {
        require(address(uniswapV3Quoter) != address(0), "Uniswap V3 quoter not set");
        
        return uniswapV3Quoter.quoteExactInputSingle(
            _tokenIn,
            _tokenOut,
            _fee,
            _inputAmount,
            0
        );
    }
    
    /**
     * @dev Estimates the amount of target tokens for V3 multi-hop swap
     * @param _path The encoded path
     * @param _inputAmount The amount of input tokens
     * @return The estimated amount of target tokens
     */
    function estimateSwapOutputV3WithPath(
        bytes calldata _path,
        uint256 _inputAmount
    ) external returns (uint256) {
        require(address(uniswapV3Quoter) != address(0), "Uniswap V3 quoter not set");
        
        return uniswapV3Quoter.quoteExactInput(_path, _inputAmount);
    }
    
    /**
     * @dev Helper function to encode V3 path for multi-hop swaps
     * @param _tokens Array of token addresses
     * @param _fees Array of fee tiers
     * @return The encoded path
     */
    function encodePath(address[] calldata _tokens, uint24[] calldata _fees) 
        external pure returns (bytes memory) {
        require(_tokens.length == _fees.length + 1, "Invalid path");
        
        bytes memory path = abi.encodePacked(_tokens[0]);
        for (uint i = 0; i < _fees.length; i++) {
            path = abi.encodePacked(path, _fees[i], _tokens[i + 1]);
        }
        return path;
    }
    
    /**
     * @dev Gets information about an order
     * @param _orderId The order ID
     * @return token The token address for this order
     * @return amount The amount of tokens in the order
     * @return rate The expected exchange rate
     * @return creator The address that created the order
     * @return refundAddress The address to refund if the order is cancelled
     * @return liquidityProvider The address of the liquidity provider
     * @return feeRecipient The address that receives protocol fees
     * @return feePercent The fee percentage in basis points
     * @return isFulfilled Whether the order has been fulfilled
     * @return isRefunded Whether the order has been refunded
     * @return timestamp The block timestamp when the order was created
     */
    function getOrderInfo(uint256 _orderId) external view returns (
        address token,
        uint256 amount,
        uint256 rate,
        address creator,
        address refundAddress,
        address liquidityProvider,
        address feeRecipient,
        uint256 feePercent,
        bool isFulfilled,
        bool isRefunded,
        uint256 timestamp
    ) {
        Order storage order = orders[_orderId];
        return (
            order.token,
            order.amount,
            order.rate,
            order.creator,
            order.refundAddress,
            order.liquidityProvider,
            order.feeRecipient,
            order.feePercent,
            order.isFulfilled,
            order.isRefunded,
            order.timestamp
        );
    }
    
    /**
     * @dev Emergency function to withdraw stuck tokens
     * @param _token The token address to withdraw
     * @param _amount The amount to withdraw
     * @param _to The address to send tokens to
     */
    function emergencyWithdraw(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOwner {
        require(_to != address(0), "Invalid recipient");
        
        if (_token == address(0)) {
            // Withdraw ETH
            (bool success, ) = _to.call{value: _amount}("");
            require(success, "ETH transfer failed");
        } else {
            // Withdraw ERC20 token
            IERC20(_token).transfer(_to, _amount);
        }
    }
    
    /**
     * @dev Batch function to set multiple token supports
     * @param _tokens Array of token addresses
     * @param _supports Array of support statuses
     */
    function batchSetTokenSupport(
        address[] calldata _tokens,
        bool[] calldata _supports
    ) external onlyOwner {
        require(_tokens.length == _supports.length, "Array length mismatch");
        
        for (uint i = 0; i < _tokens.length; i++) {
            require(_tokens[i] != address(0), "Invalid token address");
            supportedTokens[_tokens[i]] = _supports[i];
            emit TokenSupportUpdated(_tokens[i], _supports[i]);
        }
    }
    
    /**
     * @dev Get contract configuration
     * @return v2Router The Uniswap V2 router address
     * @return v3Router The Uniswap V3 router address
     * @return v3Quoter The Uniswap V3 quoter address
     * @return weth The WETH token address
     * @return totalOrders The total number of orders created
     */
    function getConfiguration() external view returns (
        address v2Router,
        address v3Router,
        address v3Quoter,
        address weth,
        uint256 totalOrders
    ) {
        return (
            address(uniswapV2Router),
            address(uniswapV3Router),
            address(uniswapV3Quoter),
            WETH,
            orderIdCounter
        );
    }
    
    /**
     * @dev Check if multiple tokens are supported
     * @param _tokens Array of token addresses to check
     * @return Array of support statuses
     */
    function areTokensSupported(address[] calldata _tokens) 
        external view returns (bool[] memory) {
        bool[] memory results = new bool[](_tokens.length);
        for (uint i = 0; i < _tokens.length; i++) {
            results[i] = supportedTokens[_tokens[i]];
        }
        return results;
    }
    
    /**
     * @dev Additional V3 function: Create order with ETH to token swap using multi-hop path
     * @param _path The encoded V3 path (must start with WETH)
     * @param _minOutputAmount The minimum amount of target tokens expected
     * @param _rate The expected exchange rate for the created order
     * @param _refundAddress The address to refund tokens if needed
     * @param _liquidityProvider The address of the liquidity provider
     * @param _feeRecipient The address to receive protocol fees
     * @param _feePercent The fee percentage in basis points
     * @return orderId The ID of the created order
     */
    function createOrderWithETHSwapV3MultiHop(
        bytes calldata _path,
        uint256 _minOutputAmount,
        uint256 _rate,
        address _refundAddress,
        address _liquidityProvider,
        address _feeRecipient,
        uint256 _feePercent
    ) external payable nonReentrant returns (uint256 orderId) {
        require(msg.value > 0, "ETH required");
        require(_minOutputAmount > 0, "Min output amount must be greater than 0");
        require(_refundAddress != address(0), "Invalid refund address");
        require(_liquidityProvider != address(0), "Invalid liquidity provider");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_feePercent <= 1000, "Fee too high");
        require(address(uniswapV3Router) != address(0), "Uniswap V3 router not set");
        require(WETH != address(0), "WETH address not set");
        
        // Extract target token from path
        address targetToken = _extractLastToken(_path);
        require(supportedTokens[targetToken], "Target token not supported");
        
        // Verify path starts with WETH
        address firstToken = _extractFirstToken(_path);
        require(firstToken == WETH, "Path must start with WETH for ETH swaps");
        
        uint256 inputAmount = msg.value;
        uint256 outputAmount = _executeETHToTokenSwapV3MultiHop(_path, inputAmount, _minOutputAmount, _refundAddress);
        
        orderId = _createOrderAfterSwap(
            targetToken,
            outputAmount,
            _rate,
            _refundAddress,
            _liquidityProvider,
            _feeRecipient,
            _feePercent
        );
    }
    
    /**
     * @dev Internal function to execute ETH to token swap using V3 multi-hop
     */
    function _executeETHToTokenSwapV3MultiHop(
        bytes calldata _path,
        uint256 _inputAmount,
        uint256 _minOutputAmount,
        address _refundAddress
    ) internal returns (uint256 outputAmount) {
        
        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: _path,
            recipient: address(this),
            amountIn: _inputAmount,
            amountOutMinimum: _minOutputAmount
        });

        try uniswapV3Router.exactInput{value: _inputAmount}(params) returns (uint256 amountOut) {
            outputAmount = amountOut;
            emit SwapExecuted(WETH, address(0), _inputAmount, outputAmount, SwapVersion.V3);
        } catch {
            // Refund ETH directly
            (bool success, ) = _refundAddress.call{value: _inputAmount}("");
            require(success, "ETH refund failed");
            revert("V3 multi-hop swap failed");
        }
    }
    
    /**
     * @dev Create order with token to ETH swap using V3
     * @param _tokenIn The input token address
     * @param _fee The fee tier for the V3 pool
     * @param _inputAmount The amount of input tokens
     * @param _minETHAmount The minimum amount of ETH expected
     * @param _rate The expected exchange rate for the created order
     * @param _refundAddress The address to refund tokens if needed
     * @param _liquidityProvider The address of the liquidity provider
     * @param _feeRecipient The address to receive protocol fees
     * @param _feePercent The fee percentage in basis points
     * @return orderId The ID of the created order
     */
    function createOrderWithTokenToETHSwapV3(
        address _tokenIn,
        uint24 _fee,
        uint256 _inputAmount,
        uint256 _minETHAmount,
        uint256 _rate,
        address _refundAddress,
        address _liquidityProvider,
        address _feeRecipient,
        uint256 _feePercent
    ) external nonReentrant returns (uint256 orderId) {
        require(_inputAmount > 0, "Input amount must be greater than 0");
        require(_minETHAmount > 0, "Min ETH amount must be greater than 0");
        require(_refundAddress != address(0), "Invalid refund address");
        require(_liquidityProvider != address(0), "Invalid liquidity provider");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_feePercent <= 1000, "Fee too high");
        require(address(uniswapV3Router) != address(0), "Uniswap V3 router not set");
        require(WETH != address(0), "WETH address not set");
        
        uint256 ethAmount = _executeTokenToETHSwapV3(_tokenIn, _fee, _inputAmount, _minETHAmount);
        
        // For ETH orders, we treat WETH as the target token
        orderId = _createOrderAfterETHSwap(
            ethAmount,
            _rate,
            _refundAddress,
            _liquidityProvider,
            _feeRecipient,
            _feePercent
        );
    }
    
    /**
     * @dev Internal function to execute token to ETH swap using V3
     */
    function _executeTokenToETHSwapV3(
        address _tokenIn,
        uint24 _fee,
        uint256 _inputAmount,
        uint256 _minETHAmount
    ) internal returns (uint256 ethAmount) {
        // Transfer input tokens from user to contract
        IERC20 inputToken = IERC20(_tokenIn);
        require(inputToken.transferFrom(msg.sender, address(this), _inputAmount), "Transfer failed");
        require(inputToken.approve(address(uniswapV3Router), _inputAmount), "Approval failed");
        
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _tokenIn,
            tokenOut: WETH,
            fee: _fee,
            recipient: address(this),
            amountIn: _inputAmount,
            amountOutMinimum: _minETHAmount,
            sqrtPriceLimitX96: 0
        });

        try uniswapV3Router.exactInputSingle(params) returns (uint256 wethAmount) {
            // Unwrap WETH to ETH
            IWETH(WETH).withdraw(wethAmount);
            ethAmount = wethAmount;
            emit SwapExecuted(_tokenIn, WETH, _inputAmount, ethAmount, SwapVersion.V3);
        } catch {
            // Refund tokens
            require(inputToken.transfer(msg.sender, _inputAmount), "Refund failed");
            revert("V3 token to ETH swap failed");
        }
    }
    
    /**
     * @dev Internal function to create order after ETH swap
     */
    function _createOrderAfterETHSwap(
        uint256 _ethAmount,
        uint256 _rate,
        address _refundAddress,
        address _liquidityProvider,
        address _feeRecipient,
        uint256 _feePercent
    ) internal returns (uint256 orderId) {
        // Calculate and deduct fee
        uint256 feeAmount = (_ethAmount * _feePercent) / 10000;
        uint256 netAmount = _ethAmount - feeAmount;

        // Transfer fees and amounts
        if (feeAmount > 0) {
            (bool feeSuccess, ) = _feeRecipient.call{value: feeAmount}("");
            require(feeSuccess, "Fee transfer failed");
        }
        (bool lpSuccess, ) = _liquidityProvider.call{value: netAmount}("");
        require(lpSuccess, "LP transfer failed");

        // Store order - using address(0) to represent ETH
        orderId = orderIdCounter++;
        orders[orderId] = Order({
            token: address(0), // ETH represented as address(0)
            amount: _ethAmount,
            rate: _rate,
            creator: msg.sender,
            refundAddress: _refundAddress,
            liquidityProvider: _liquidityProvider,
            feeRecipient: _feeRecipient,
            feePercent: _feePercent,
            isFulfilled: true,
            isRefunded: false,
            timestamp: block.timestamp
        });

        emit OrderCreated(orderId, address(0), _ethAmount, _rate, _refundAddress, _liquidityProvider, _feeRecipient, _feePercent);
        emit OrderFulfilled(orderId, _liquidityProvider);
    }
}