// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Importaciones de OpenZeppelin para seguridad y control de acceso
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Interfaz de Chainlink para los Data Feeds
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

// Interfaz para obtener los decimales de tokens ERC-20
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

// Interfaz del Router de Uniswap V2
interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);
    
    function getAmountsOut(
        uint amountIn,
        address[] calldata path
    ) external view returns (uint[] memory amounts);
}

// Interfaz de Uniswap V2 Factory
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @title KipuBankV3 - Bóveda Multi-token con Integración Uniswap V2
/// @author JuanCruzSaladino / Gemini / Claude
/**
 * @notice KipuBankV3 permite a usuarios depositar ETH y tokens ERC-20,
 * intercambiándolos automáticamente a USDC mediante Uniswap V2.
 * - Todos los balances internos se mantienen en USDC.
 * - El límite global bankCapUSD se controla en valor USDC.
 * - Soporta depósitos de cualquier token con par en Uniswap V2.
 * - Los retiros se realizan en USDC.
 */
contract KipuBankV3 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    /////////////////////////////////////////////////////////////*/
    
    /// @notice Constante que representa el token nativo (ETH) en el sistema.
    address private constant ETH_ADDRESS = address(0);
    
    /// @notice Número de decimales utilizados para USDC (6 decimales).
    uint256 private constant USDC_DECIMALS = 6;
    
    /// @notice Tiempo máximo que se considera válido un precio de Chainlink (1 hora = 3600 segundos).
    uint256 private constant STALE_PRICE_LIMIT = 3600;
    
    /// @notice Slippage máximo permitido en swaps (5% = 500 basis points).
    uint256 private constant MAX_SLIPPAGE_BPS = 500;
    uint256 private constant BPS_DENOMINATOR = 10000;
    
    /// @notice Deadline para transacciones de Uniswap (15 minutos).
    uint256 private constant SWAP_DEADLINE_BUFFER = 15 minutes;

    /*//////////////////////////////////////////////////////////////
                         STATE VARIABLES
    /////////////////////////////////////////////////////////////*/
    
    /// @notice Dirección del token USDC.
    address public immutable USDC;
    
    /// @notice Dirección del Router de Uniswap V2.
    IUniswapV2Router02 public immutable uniswapRouter;
    
    /// @notice Dirección de la Factory de Uniswap V2.
    IUniswapV2Factory public immutable uniswapFactory;
    
    /// @notice Balances de los usuarios en USDC (6 decimales).
    mapping(address => uint256) private balances;
    
    /// @notice Mapeo de la dirección del token a su Chainlink Data Feed Address.
    mapping(address => AggregatorV3Interface) public tokenPriceFeeds;
    
    /// @notice Contador de depósitos por usuario.
    mapping(address => uint256) private userDepositCount;
    
    /// @notice Contador de retiros por usuario.
    mapping(address => uint256) private userWithdrawalCount;
    
    /// @notice Contador total de depósitos del banco.
    uint256 public totalDepositsCount;
    
    /// @notice Contador total de retiros del banco.
    uint256 public totalWithdrawalsCount;
    
    /// @notice Valor total actual en USDC de todos los activos del banco.
    uint256 private totalBankBalanceUSDC;
    
    /// @notice Límite global máximo de depósitos del banco en USDC (6 decimales).
    uint256 public immutable bankCapUSD;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    /////////////////////////////////////////////////////////////*/
    
    /// @notice Emitido cuando un usuario deposita un activo.
    event DepositMade(
        address indexed user,
        address indexed token,
        uint256 amountIn,
        uint256 amountUSDC
    );
    
    /// @notice Emitido cuando se realiza un swap.
    event SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut
    );
    
    /// @notice Emitido cuando un usuario retira USDC.
    event WithdrawalMade(
        address indexed user,
        uint256 amount
    );
    
    /// @notice Emitido cuando se establece o actualiza un Data Feed de precios.
    event PriceFeedUpdated(address indexed token, address indexed feedAddress);

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    /////////////////////////////////////////////////////////////*/
    
    error KipuBank_ZeroAmount();
    error KipuBank_ZeroAddress();
    error KipuBank_BankCapExceeded(uint256 attemptedAmount, uint256 newTotal, uint256 cap);
    error KipuBank_InsufficientBalance(uint256 requested, uint256 available);
    error KipuBank_TransferFailed(address to, uint256 amount);
    error KipuBank_NoPriceFeed();
    error KipuBank_InvalidPrice(int256 price);
    error KipuBank_StalePrice(uint256 timeSinceUpdate, uint256 limit);
    error KipuBank_NoPairFound(address token);
    error KipuBank_SlippageTooHigh(uint256 expected, uint256 minimum);
    error KipuBank_SwapFailed();

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR
    /////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Inicializa el banco con un límite global de depósitos en USDC.
     * @param _bankCapUSD Límite de depósitos en USDC (6 decimales).
     * @param _usdc Dirección del token USDC.
     * @param _uniswapRouter Dirección del Router de Uniswap V2.
     */
    constructor(
        uint256 _bankCapUSD,
        address _usdc,
        address _uniswapRouter
    ) Ownable(msg.sender) ReentrancyGuard() {
        if (_usdc == address(0) || _uniswapRouter == address(0)) {
            revert KipuBank_ZeroAddress();
        }
        
        bankCapUSD = _bankCapUSD;
        USDC = _usdc;
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);
        uniswapFactory = IUniswapV2Factory(uniswapRouter.factory());
    }

    /*//////////////////////////////////////////////////////////////
                      RECEIVE / FALLBACK HANDLERS
    /////////////////////////////////////////////////////////////*/
    
    /// @notice Maneja depósitos de ETH nativo.
    receive() external payable {
        if (msg.value == 0) revert KipuBank_ZeroAmount();
        _depositETH(msg.value);
    }
    
    /// @notice Maneja la llamada a fallback. Solo soporta depósitos de ETH.
    fallback() external payable {
        if (msg.value > 0) {
            _depositETH(msg.value);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        FUNCIONES ADMIN
    /////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Permite al dueño establecer el Chainlink Data Feed para un token.
     * @param token La dirección del token (use address(0) para ETH).
     * @param feedAddress La dirección del oráculo de Chainlink para ese token.
     */
    function setTokenPriceFeed(address token, address feedAddress) external onlyOwner {
        tokenPriceFeeds[token] = AggregatorV3Interface(feedAddress);
        emit PriceFeedUpdated(token, feedAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           CORE LOGIC
    /////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Permite al usuario depositar ETH en su bóveda.
     * @dev ETH se intercambia automáticamente a USDC.
     */
    function depositETH() external payable nonReentrant {
        if (msg.value == 0) revert KipuBank_ZeroAmount();
        _depositETH(msg.value);
    }
    
    /**
     * @notice Permite al usuario depositar un token ERC-20.
     * @dev Si es USDC, se almacena directamente. Si no, se intercambia a USDC.
     * @param token Dirección del token ERC-20 a depositar.
     * @param amount Cantidad del token a depositar (en sus decimales nativos).
     */
    function depositERC20(address token, uint256 amount) external nonReentrant {
        if (token == ETH_ADDRESS || token == address(0)) revert KipuBank_ZeroAddress();
        if (amount == 0) revert KipuBank_ZeroAmount();
        
        // CHECKS & INTERACTIONS: Transfiere el token desde el usuario al contrato
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        // EFFECTS: Ejecuta la lógica de depósito
        if (token == USDC) {
            _depositUSDCDirect(amount);
        } else {
            _depositAndSwapToUSDC(token, amount);
        }
    }
    
    /**
     * @notice Permite al usuario retirar USDC de su bóveda.
     * @param amount Cantidad de USDC a retirar (6 decimales).
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert KipuBank_ZeroAmount();
        
        // CHECKS
        uint256 userBalance = balances[msg.sender];
        if (amount > userBalance) {
            revert KipuBank_InsufficientBalance(amount, userBalance);
        }
        
        // EFFECTS
        unchecked {
            balances[msg.sender] = userBalance - amount;
            totalBankBalanceUSDC -= amount;
            userWithdrawalCount[msg.sender] += 1;
            totalWithdrawalsCount += 1;
        }
        
        // INTERACTIONS
        IERC20(USDC).safeTransfer(msg.sender, amount);
        
        emit WithdrawalMade(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        PRIVATE / INTERNAL
    /////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Lógica privada de depósito de ETH con swap a USDC.
     * @param amount Cantidad de ETH depositado (en wei).
     */
    function _depositETH(uint256 amount) private {
        // Verificar que exista un par ETH/USDC
        address weth = uniswapRouter.WETH();
        address pair = uniswapFactory.getPair(weth, USDC);
        if (pair == address(0)) revert KipuBank_NoPairFound(ETH_ADDRESS);
        
        // Calcular el mínimo aceptable con slippage
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = USDC;
        
        uint256[] memory amountsOut = uniswapRouter.getAmountsOut(amount, path);
        uint256 expectedUSDC = amountsOut[1];
        uint256 minUSDC = (expectedUSDC * (BPS_DENOMINATOR - MAX_SLIPPAGE_BPS)) / BPS_DENOMINATOR;
        
        // Verificar límite del banco ANTES del swap
        uint256 newTotal = totalBankBalanceUSDC + expectedUSDC;
        if (newTotal > bankCapUSD) {
            revert KipuBank_BankCapExceeded(expectedUSDC, newTotal, bankCapUSD);
        }
        
        // Ejecutar swap de ETH a USDC
        uint256[] memory amounts = uniswapRouter.swapExactETHForTokens{value: amount}(
            minUSDC,
            path,
            address(this),
            block.timestamp + SWAP_DEADLINE_BUFFER
        );
        
        uint256 usdcReceived = amounts[1];
        
        // Verificar nuevamente con el monto real recibido
        newTotal = totalBankBalanceUSDC + usdcReceived;
        if (newTotal > bankCapUSD) {
            revert KipuBank_BankCapExceeded(usdcReceived, newTotal, bankCapUSD);
        }
        
        // EFFECTS
        unchecked {
            balances[msg.sender] += usdcReceived;
            totalBankBalanceUSDC = newTotal;
            userDepositCount[msg.sender] += 1;
            totalDepositsCount += 1;
        }
        
        emit SwapExecuted(msg.sender, ETH_ADDRESS, amount, usdcReceived);
        emit DepositMade(msg.sender, ETH_ADDRESS, amount, usdcReceived);
    }
    
    /**
     * @notice Lógica privada de depósito directo de USDC.
     * @param amount Cantidad de USDC depositado (6 decimales).
     */
    function _depositUSDCDirect(uint256 amount) private {
        // CHECKS
        uint256 newTotal = totalBankBalanceUSDC + amount;
        if (newTotal > bankCapUSD) {
            revert KipuBank_BankCapExceeded(amount, newTotal, bankCapUSD);
        }
        
        // EFFECTS
        unchecked {
            balances[msg.sender] += amount;
            totalBankBalanceUSDC = newTotal;
            userDepositCount[msg.sender] += 1;
            totalDepositsCount += 1;
        }
        
        emit DepositMade(msg.sender, USDC, amount, amount);
    }
    
    /**
     * @notice Lógica privada de depósito de token ERC20 con swap a USDC.
     * @param token Dirección del token depositado.
     * @param amount Cantidad del token depositado (en sus decimales nativos).
     */
    function _depositAndSwapToUSDC(address token, uint256 amount) private {
        // Verificar que exista un par directo token/USDC
        address pair = uniswapFactory.getPair(token, USDC);
        if (pair == address(0)) revert KipuBank_NoPairFound(token);
        
        // Aprobar el router para gastar el token usando SafeERC20
        IERC20(token).safeIncreaseAllowance(address(uniswapRouter), amount);
        
        // Calcular el mínimo aceptable con slippage
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = USDC;
        
        uint256[] memory amountsOut = uniswapRouter.getAmountsOut(amount, path);
        uint256 expectedUSDC = amountsOut[1];
        uint256 minUSDC = (expectedUSDC * (BPS_DENOMINATOR - MAX_SLIPPAGE_BPS)) / BPS_DENOMINATOR;
        
        // Verificar límite del banco ANTES del swap
        uint256 newTotal = totalBankBalanceUSDC + expectedUSDC;
        if (newTotal > bankCapUSD) {
            revert KipuBank_BankCapExceeded(expectedUSDC, newTotal, bankCapUSD);
        }
        
        // Ejecutar swap de token a USDC
        uint256[] memory amounts = uniswapRouter.swapExactTokensForTokens(
            amount,
            minUSDC,
            path,
            address(this),
            block.timestamp + SWAP_DEADLINE_BUFFER
        );
        
        uint256 usdcReceived = amounts[1];
        
        // Verificar nuevamente con el monto real recibido
        newTotal = totalBankBalanceUSDC + usdcReceived;
        if (newTotal > bankCapUSD) {
            revert KipuBank_BankCapExceeded(usdcReceived, newTotal, bankCapUSD);
        }
        
        // EFFECTS
        unchecked {
            balances[msg.sender] += usdcReceived;
            totalBankBalanceUSDC = newTotal;
            userDepositCount[msg.sender] += 1;
            totalDepositsCount += 1;
        }
        
        emit SwapExecuted(msg.sender, token, amount, usdcReceived);
        emit DepositMade(msg.sender, token, amount, usdcReceived);
    }

    /*//////////////////////////////////////////////////////////////
                         VIEW FUNCTIONS
    /////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Retorna el balance de un usuario en USDC.
     * @param user La dirección del usuario.
     * @return balance El balance en USDC (6 decimales).
     */
    function getBalance(address user) external view returns (uint256 balance) {
        return balances[user];
    }
    
    /**
     * @notice Retorna el balance total actual del banco en USDC.
     * @return bankBalanceUSDC El valor total del banco en USDC (6 decimales).
     */
    function getTotalBankBalanceUSDC() external view returns (uint256 bankBalanceUSDC) {
        return totalBankBalanceUSDC;
    }
    
    /**
     * @notice Retorna las estadísticas globales de depósitos y retiros.
     * @return totalDeposits El número total de depósitos realizados.
     * @return totalWithdrawals El número total de retiros realizados.
     */
    function getGlobalStats() external view returns (uint256 totalDeposits, uint256 totalWithdrawals) {
        return (totalDepositsCount, totalWithdrawalsCount);
    }
    
    /**
     * @notice Retorna las estadísticas de depósitos y retiros para un usuario.
     * @param user La dirección del usuario.
     * @return deposits El número de depósitos hechos por el usuario.
     * @return withdrawals El número de retiros hechos por el usuario.
     */
    function getUserStats(address user) external view returns (uint256 deposits, uint256 withdrawals) {
        return (userDepositCount[user], userWithdrawalCount[user]);
    }
    
    /**
     * @notice Verifica si existe un par de Uniswap para un token con USDC.
     * @param token Dirección del token a verificar.
     * @return exists True si existe el par, false en caso contrario.
     */
    function hasPairWithUSDC(address token) external view returns (bool exists) {
        if (token == USDC) return true;
        
        address pairAddress;
        if (token == ETH_ADDRESS) {
            pairAddress = uniswapFactory.getPair(uniswapRouter.WETH(), USDC);
        } else {
            pairAddress = uniswapFactory.getPair(token, USDC);
        }
        return pairAddress != address(0);
    }
    
    /**
     * @notice Estima cuánto USDC se recibirá por un depósito de token.
     * @param token Dirección del token (address(0) para ETH).
     * @param amount Cantidad del token.
     * @return estimatedUSDC Cantidad estimada de USDC (6 decimales).
     */
    function estimateDepositOutput(address token, uint256 amount) 
        external 
        view 
        returns (uint256 estimatedUSDC) 
    {
        if (token == USDC) return amount;
        
        address[] memory path = new address[](2);
        if (token == ETH_ADDRESS) {
            path[0] = uniswapRouter.WETH();
        } else {
            path[0] = token;
        }
        path[1] = USDC;
        
        uint256[] memory amountsOut = uniswapRouter.getAmountsOut(amount, path);
        return amountsOut[1];
    }
}