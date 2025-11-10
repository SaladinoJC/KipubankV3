# KipuBankV3 - Bóveda Multi-token con Integración Uniswap V2

## 📋 Tabla de Contenidos

- [Descripción General](#descripción-general)
- [Mejoras Implementadas](#mejoras-implementadas)
- [Arquitectura del Sistema](#arquitectura-del-sistema)
- [Instalación y Despliegue](#instalación-y-despliegue)
- [Guía de Interacción](#guía-de-interacción)
- [Decisiones de Diseño](#decisiones-de-diseño)
- [Trade-offs y Consideraciones](#trade-offs-y-consideraciones)
- [Seguridad](#seguridad)
- [Testing](#testing)

---

## 🎯 Descripción General

**KipuBankV3** es una evolución del sistema de bóveda multi-token que permite a los usuarios depositar ETH y cualquier token ERC20 con liquidez en Uniswap V2, convirtiéndolos automáticamente a USDC para almacenamiento unificado.

### Características Principales

- ✅ **Depósitos multi-token**: ETH y cualquier ERC20 con par en Uniswap V2
- ✅ **Conversión automática a USDC**: Todos los activos se convierten y almacenan en USDC
- ✅ **Límite global en USDC**: Control preciso del capital total del banco
- ✅ **Protección contra slippage**: 5% máximo en todos los swaps
- ✅ **Seguridad reforzada**: ReentrancyGuard, SafeERC20, Checks-Effects-Interactions
- ✅ **Gas optimizado**: Balance unificado reduce costos de lectura

---

## 🚀 Mejoras Implementadas

### 1. **Integración con Uniswap V2**

**¿Por qué?** 
- Permite soportar cientos de tokens sin necesidad de integraciones individuales
- Aprovecha la liquidez descentralizada existente
- Elimina dependencia de oráculos para precios de tokens menos comunes

**Cómo funciona:**
```solidity
// Verificación de par antes del swap
address pair = uniswapFactory.getPair(token, USDC);
if (pair == address(0)) revert KipuBank_NoPairFound(token);

// Swap automático con protección de slippage
uint256[] memory amounts = uniswapRouter.swapExactTokensForTokens(
    amount,
    minUSDC, // 5% de tolerancia al slippage
    path,
    address(this),
    deadline
);
```

### 2. **Sistema de Balance Unificado en USDC**

**¿Por qué?**
- **Simplificación contable**: Un solo mapping en lugar de doble mapping
- **Claridad del límite**: `bankCapUSD` se controla directamente en USDC
- **Menor complejidad**: No se necesita conversión USD para cada consulta
- **Ahorro de gas**: Menos storage slots a leer/escribir

**Antes (V2):**
```solidity
mapping(address => mapping(address => uint256)) private balances; // Usuario -> Token -> Cantidad
uint256 private totalBankBalanceUSD; // Requiere cálculo constante
```

**Ahora (V3):**
```solidity
mapping(address => uint256) private balances; // Usuario -> Cantidad en USDC
uint256 private totalBankBalanceUSDC; // Directo, sin conversión
```

### 3. **Depósitos Generalizados con Verificación de Liquidez**

**¿Por qué?**
- **Flexibilidad**: Los usuarios pueden depositar cualquier token popular
- **Sin whitelist**: No requiere aprobación previa de tokens
- **Auto-validación**: El contrato verifica automáticamente si existe liquidez

**Flujo de depósito:**
```
Usuario deposita TOKEN X
    ↓
¿Es USDC? → SÍ → Almacenar directamente
    ↓ NO
¿Existe par TOKEN/USDC en Uniswap? → NO → ❌ Revert
    ↓ SÍ
Calcular swap estimado
    ↓
¿Excede bankCap? → SÍ → ❌ Revert
    ↓ NO
Ejecutar swap con protección de slippage
    ↓
Verificar monto real recibido vs bankCap
    ↓
✅ Acreditar USDC al usuario
```

### 4. **Doble Verificación del Bank Cap**

**¿Por qué?**
- **Seguridad**: El slippage podría causar que recibamos más USDC de lo estimado
- **Prevención de overflow**: Evita sobrepasar el límite por condiciones de mercado

**Implementación:**
```solidity
// Primera verificación: con monto estimado
uint256 expectedUSDC = amountsOut[1];
uint256 newTotal = totalBankBalanceUSDC + expectedUSDC;
if (newTotal > bankCapUSD) revert KipuBank_BankCapExceeded(...);

// Ejecutar swap
uint256[] memory amounts = uniswapRouter.swapExactTokensForTokens(...);
uint256 usdcReceived = amounts[1];

// Segunda verificación: con monto real
newTotal = totalBankBalanceUSDC + usdcReceived;
if (newTotal > bankCapUSD) revert KipuBank_BankCapExceeded(...);
```

### 5. **Protección Contra Slippage**

**¿Por qué?**
- **Protección del usuario**: Evita pérdidas por manipulación de precios
- **Front-running protection**: Dificulta ataques MEV
- **Transparencia**: Los usuarios saben el mínimo que recibirán

**Cálculo:**
```solidity
uint256 MAX_SLIPPAGE_BPS = 500; // 5%
uint256 minUSDC = (expectedUSDC * (10000 - 500)) / 10000;
// Si el precio varía más del 5%, la transacción revierte
```

---

## 🏗️ Arquitectura del Sistema

### Diagrama de Flujo

```
┌─────────────────────────────────────────────────────────┐
│                     KipuBankV3                          │
│                                                         │
│  ┌────────────┐    ┌──────────────┐    ┌────────────┐ │
│  │  Depósito  │───▶│ Verificación │───▶│   Swap     │ │
│  │   ETH/ERC20│    │ de Par       │    │ Uniswap V2 │ │
│  └────────────┘    └──────────────┘    └────────────┘ │
│                            │                    │       │
│                            ▼                    ▼       │
│                    ┌──────────────┐    ┌────────────┐ │
│                    │ Verificación │    │  Balance   │ │
│                    │  Bank Cap    │    │   USDC     │ │
│                    └──────────────┘    └────────────┘ │
│                                                         │
│  ┌────────────┐                                        │
│  │   Retiro   │◀────────────────────────────────────  │
│  │    USDC    │                                        │
│  └────────────┘                                        │
└─────────────────────────────────────────────────────────┘
         │                                        │
         ▼                                        ▼
┌─────────────────┐                    ┌──────────────────┐
│  Uniswap V2     │                    │  Usuario         │
│  Router/Factory │                    │  EOA/Contract    │
└─────────────────┘                    └──────────────────┘
```

### Componentes Clave

1. **Uniswap V2 Router**: Ejecuta los swaps de tokens
2. **Uniswap V2 Factory**: Verifica existencia de pares de liquidez
3. **USDC**: Token de almacenamiento unificado
4. **Mappings de Balance**: Almacenamiento eficiente de saldos

---

## 📦 Instalación y Despliegue

### Requisitos Previos

- Solidity `^0.8.30`
- OpenZeppelin Contracts `^4.9.0` o `^5.0.0`
- Red con Uniswap V2 desplegado
- Token USDC en la red objetivo

### Paso 1: Compilación en Remix

1. Abre [Remix IDE](https://remix.ethereum.org)
2. Crea `KipuBankV3.sol` y pega el código
3. Compila con:
   - **Compiler**: `0.8.30`
   - **Optimization**: ✅ Enabled (200 runs)
   - **EVM Version**: `paris` o `london`

### Paso 2: Parámetros de Despliegue

```solidity
constructor(
    uint256 _bankCapUSD,      // Límite en USDC (6 decimales)
    address _usdc,            // Dirección del token USDC
    address _uniswapRouter    // Router de Uniswap V2
)
```

### Paso 3: Direcciones por Red

#### **Ethereum Mainnet**
```javascript
bankCapUSD: 1000000000000        // 1,000,000 USDC
USDC: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
Router: "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D"
```

#### **Sepolia Testnet**
```javascript
bankCapUSD: 100000000000         // 100,000 USDC
USDC: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
Router: "0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008"
```

#### **Polygon**
```javascript
bankCapUSD: 1000000000000
USDC: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
Router: "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff"  // QuickSwap
```

#### **Arbitrum**
```javascript
bankCapUSD: 1000000000000
USDC: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"
Router: "0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24"
```

### Paso 4: Deploy desde Remix

```javascript
// En el campo de deploy de Remix:
1000000000000,"0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48","0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D"
```

### Paso 5: Verificación en Etherscan

1. **Flatten el contrato**:
   - Click derecho en `KipuBankV3.sol` → "Flatten"
   - Copia el contenido de `KipuBankV3_flattened.sol`

2. **Verificar**:
   - Ve a tu contrato en Etherscan
   - "Contract" → "Verify and Publish"
   - **Compiler Type**: `Solidity (Single file)`
   - **Compiler Version**: `v0.8.30`
   - **Optimization**: `Yes` (200 runs)
   - **License**: `MIT`
   - Pega el código flattened
   - Agrega los **Constructor Arguments** (ABI-encoded)

---

## 💻 Guía de Interacción

### 1. Depositar ETH

```javascript
// Opción A: Llamar depositETH()
await kipuBank.depositETH({ value: ethers.parseEther("1.0") });

// Opción B: Enviar ETH directamente (receive/fallback)
await signer.sendTransaction({
    to: kipuBankAddress,
    value: ethers.parseEther("0.5")
});
```

### 2. Depositar USDC (Directo)

```javascript
// 1. Aprobar el contrato
const usdc = new ethers.Contract(usdcAddress, erc20Abi, signer);
await usdc.approve(kipuBankAddress, ethers.parseUnits("100", 6));

// 2. Depositar
await kipuBank.depositERC20(usdcAddress, ethers.parseUnits("100", 6));
```

### 3. Depositar Otro Token (Se Convierte a USDC)

```javascript
// Ejemplo: Depositar DAI
const dai = new ethers.Contract(daiAddress, erc20Abi, signer);

// 1. Verificar si existe par con USDC
const hasPair = await kipuBank.hasPairWithUSDC(daiAddress);
if (!hasPair) {
    console.error("No existe liquidez DAI/USDC en Uniswap");
    return;
}

// 2. Estimar cuánto USDC recibirás
const estimatedUSDC = await kipuBank.estimateDepositOutput(
    daiAddress, 
    ethers.parseEther("100")
);
console.log(`Recibirás ~${ethers.formatUnits(estimatedUSDC, 6)} USDC`);

// 3. Aprobar
await dai.approve(kipuBankAddress, ethers.parseEther("100"));

// 4. Depositar (se swapea automáticamente a USDC)
await kipuBank.depositERC20(daiAddress, ethers.parseEther("100"));
```

### 4. Consultar Balance

```javascript
const balance = await kipuBank.getBalance(userAddress);
console.log(`Balance: ${ethers.formatUnits(balance, 6)} USDC`);

// Balance total del banco
const totalBalance = await kipuBank.getTotalBankBalanceUSDC();
console.log(`Total en banco: ${ethers.formatUnits(totalBalance, 6)} USDC`);
```

### 5. Retirar USDC

```javascript
// Retirar 50 USDC
await kipuBank.withdraw(ethers.parseUnits("50", 6));
```

### 6. Ver Estadísticas

```javascript
// Estadísticas del usuario
const [deposits, withdrawals] = await kipuBank.getUserStats(userAddress);
console.log(`Depósitos: ${deposits}, Retiros: ${withdrawals}`);

// Estadísticas globales
const [totalDeposits, totalWithdrawals] = await kipuBank.getGlobalStats();
console.log(`Total depósitos: ${totalDeposits}, Total retiros: ${totalWithdrawals}`);
```

### 7. Funciones de Admin (Solo Owner)

```javascript
// Establecer price feed de Chainlink (opcional, no usado en V3)
await kipuBank.setTokenPriceFeed(
    ethers.ZeroAddress, // ETH
    "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419" // ETH/USD Chainlink
);
```

---

## 🎨 Decisiones de Diseño

### 1. **Balance Unificado en USDC**

**Decisión**: Todos los activos se convierten y almacenan en USDC.

**Razones**:
- ✅ **Simplicidad**: Un solo token para gestionar
- ✅ **Gas Eficiente**: Menos lecturas de storage
- ✅ **Límite Preciso**: Control directo del `bankCapUSD`
- ✅ **Liquidez**: USDC es el activo más líquido en DeFi

**Alternativas Consideradas**:
- ❌ Mantener tokens individuales (complejidad de contabilidad)
- ❌ Usar ETH como base (mayor volatilidad)

### 2. **Solo Pares Directos con USDC**

**Decisión**: Solo se permiten tokens con par directo TOKEN/USDC en Uniswap.

**Razones**:
- ✅ **Menor Slippage**: Rutas directas son más eficientes
- ✅ **Gas Optimizado**: Un solo swap vs múltiples
- ✅ **Precios Confiables**: Pares directos tienen mejor liquidez
- ✅ **Menor Complejidad**: No requiere routing inteligente

**Alternativas Consideradas**:
- ❌ Multi-hop routing (TOKEN → ETH → USDC): Mayor gas y slippage
- ❌ Agregador de DEXs: Mayor complejidad

### 3. **Retiros Solo en USDC**

**Decisión**: Los usuarios solo pueden retirar USDC, no el token original.

**Razones**:
- ✅ **Simplicidad**: No necesitamos mantener inventario de múltiples tokens
- ✅ **Sin Swap Reverso**: Evita problemas de liquidez en retiros
- ✅ **Previsibilidad**: El usuario sabe exactamente qué recibirá
- ✅ **Stablecoin**: Menos riesgo de volatilidad durante el retiro

**Trade-off Aceptado**:
- ⚠️ El usuario debe swapear manualmente si quiere otro token

### 4. **Slippage Fijo del 5%**

**Decisión**: Slippage máximo hardcoded en 5% (500 basis points).

**Razones**:
- ✅ **Protección Automática**: No requiere input del usuario
- ✅ **Balance**: 5% es generoso pero protege contra manipulación
- ✅ **Gas Eficiente**: No hay parámetro adicional en cada llamada

**Alternativas Consideradas**:
- ❌ Slippage configurable por usuario: Más complejidad, mayor gas
- ❌ Slippage más bajo (1-2%): Muchas transacciones fallarían en alta volatilidad

### 5. **Deadline de 15 Minutos**

**Decisión**: Todas las transacciones de Uniswap tienen deadline de `block.timestamp + 15 minutes`.

**Razones**:
- ✅ **Seguridad**: Evita que transacciones queden pendientes indefinidamente
- ✅ **Balance**: 15 min es suficiente para inclusión en bloque
- ✅ **Sin Input Usuario**: Simplifica la interfaz

### 6. **Uso de `safeIncreaseAllowance` en lugar de `approve`**

**Decisión**: Usamos `safeIncreaseAllowance` de OpenZeppelin.

**Razones**:
- ✅ **Seguridad**: Evita race conditions en approvals
- ✅ **No Requiere Reset**: No necesitamos `approve(0)` primero
- ✅ **Best Practice**: Recomendado por OpenZeppelin

**Código**:
```solidity
// ❌ Antiguo (vulnerable a race conditions)
IERC20(token).approve(router, amount);

// ✅ Nuevo (seguro)
IERC20(token).safeIncreaseAllowance(router, amount);
```

### 7. **Doble Verificación del Bank Cap**

**Decisión**: Verificamos el límite antes y después del swap.

**Razones**:
- ✅ **Prevención de Overflow**: El slippage positivo no debe exceder el cap
- ✅ **Seguridad Adicional**: Redundancia ante bugs
- ✅ **Costo Mínimo**: Solo una comparación extra

### 8. **Inmutabilidad de Parámetros Críticos**

**Decisión**: `bankCapUSD`, `USDC`, y `uniswapRouter` son immutable.

**Razones**:
- ✅ **Gas Eficiente**: Variables immutable son más baratas de leer
- ✅ **Seguridad**: No pueden ser cambiadas maliciosamente
- ✅ **Confianza**: Los usuarios saben que las reglas no cambiarán

**Trade-off Aceptado**:
- ⚠️ Si Uniswap actualiza su router, necesitamos redeployar

---

## ⚖️ Trade-offs y Consideraciones

### 1. **Gas Costs**

| Operación | Gas Estimado | Notas |
|-----------|--------------|-------|
| Depositar USDC | ~50k | Sin swap, solo transferencia |
| Depositar ETH | ~150-200k | Incluye swap en Uniswap |
| Depositar ERC20 | ~180-250k | Transferencia + approve + swap |
| Retirar USDC | ~45k | Solo transferencia |

**Trade-off**: Swaps automáticos aumentan el gas vs versión V2, pero simplifican UX.

### 2. **Dependencia de Uniswap V2**

**Pro**:
- ✅ Protocolo battle-tested y probado
- ✅ Mayor liquidez en muchos pares
- ✅ Código de fuente abierto y auditado

**Contra**:
- ⚠️ Si Uniswap V2 tiene problemas, afecta nuestro contrato
- ⚠️ Dependencia de liquidez externa
- ⚠️ No podemos usar V3 (más eficiente pero más complejo)

**Mitigación**: Los usuarios pueden depositar USDC directamente (sin usar Uniswap).

### 3. **Slippage y Front-Running**

**Problema**: Los swaps pueden ser front-run en la mempool.

**Mitigación Implementada**:
- Slippage máximo del 5%
- Deadline de 15 minutos
- Los usuarios pueden usar flashbots/private RPCs

**Limitación Aceptada**: No podemos eliminar completamente el MEV.

### 4. **Tokens con Fees en Transfer**

**Problema**: Algunos tokens (ej. USDT con fee activo) deducen un fee en transfers.

**Comportamiento**:
- El swap puede resultar en menos USDC de lo esperado
- La verificación de slippage protege parcialmente
- Si el fee es >5%, la transacción revertirá

**Recomendación**: Usar tokens sin transfer fees cuando sea posible.

### 5. **Tokens Rebasing o con Balance Dinámico**

**Problema**: Tokens como stETH o aTokens cambian su balance con el tiempo.

**Limitación**: **No soportados** en este contrato.

**Razón**: El swap a USDC "congela" el valor en el momento del depósito.

### 6. **Liquidez Insuficiente**

**Escenario**: Un usuario intenta depositar un monto grande de un token con baja liquidez.

**Comportamiento**:
- El slippage será mayor al 5%
- La transacción revertirá con error de slippage

**Mitigación**: El usuario puede:
- Depositar en montos más pequeños
- Usar `estimateDepositOutput()` antes para verificar
- Depositar USDC directamente

### 7. **Centralización del Owner**

**Poder del Owner**:
- ✅ Puede establecer price feeds (no usado en V3)
- ❌ **NO** puede retirar fondos de usuarios
- ❌ **NO** puede cambiar el bankCap
- ❌ **NO** puede pausar depósitos/retiros

**Mitigación**: Considerar transferir ownership a un multisig o DAO.

### 8. **Ausencia de Pausabilidad**

**Decisión**: No implementamos pausa de emergencia.

**Razones**:
- ✅ Mayor descentralización
- ✅ Los usuarios siempre pueden retirar

**Trade-off**:
- ⚠️ Si se descubre un bug crítico, no podemos pausar
- ⚠️ Dependemos de auditorías exhaustivas

**Alternativa Futura**: Agregar `Pausable` de OpenZeppelin en V4.

---

## 🔒 Seguridad

### Medidas Implementadas

#### 1. **ReentrancyGuard**
```solidity
contract KipuBankV3 is Ownable, ReentrancyGuard {
    function depositETH() external payable nonReentrant { ... }
    function withdraw(uint256 amount) external nonReentrant { ... }
}
```
- Protege contra ataques de reentrancia
- Aplicado en todas las funciones externas que modifican estado

#### 2. **SafeERC20**
```solidity
using SafeERC20 for IERC20;

IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
IERC20(USDC).safeTransfer(msg.sender, amount);
```
- Maneja tokens que no retornan `bool` en transferencias
- Revierte automáticamente en transfers fallidos

#### 3. **Checks-Effects-Interactions**
```solidity
// ✅ CHECKS
if (amount == 0) revert KipuBank_ZeroAmount();
if (amount > userBalance) revert KipuBank_InsufficientBalance(...);

// ✅ EFFECTS
balances[msg.sender] -= amount;
totalBankBalanceUSDC -= amount;

// ✅ INTERACTIONS
IERC20(USDC).safeTransfer(msg.sender, amount);
```

#### 4. **Custom Errors (Gas Optimized)**
```solidity
error KipuBank_BankCapExceeded(uint256 attempted, uint256 newTotal, uint256 cap);
error KipuBank_InsufficientBalance(uint256 requested, uint256 available);
```
- Más eficientes en gas que `require` strings
- Información detallada para debugging

#### 5. **Validación de Inputs**
- Zero amount checks
- Zero address checks
- Balance sufficiency checks
- Pair existence checks

#### 6. **Immutable Variables Críticas**
```solidity
uint256 public immutable bankCapUSD;
address public immutable USDC;
IUniswapV2Router02 public immutable uniswapRouter;
```

### Vectores de Ataque Mitigados

| Ataque | Mitigación |
|--------|------------|
| Reentrancy | `nonReentrant` modifier |
| Integer Overflow | Solidity 0.8.x (built-in) |
| Front-running MEV | Slippage protection del 5% |
| Manipulación de precios | Pares de Uniswap (TWAP implícito) |
| Aprobaciones maliciosas | `safeIncreaseAllowance` |
| Tokens maliciosos | Verificación de pares + SafeERC20 |

### Consideraciones de Auditoría

**Áreas Críticas para Auditar**:
1. ✅ Lógica de swap y cálculo de slippage
2. ✅ Doble verificación del bankCap
3. ✅ Manejo de decimales (USDC usa 6, otros tokens 18)
4. ✅ Flujo completo de depósito/retiro
5. ✅ Interacción con Uniswap Router

**Recomendaciones**:
- Realizar auditoría profesional antes de mainnet
- Implementar timelock en funciones admin (si se agregan más)
- Considerar bug bounty program

---

## 🧪 Testing

### Tests Recomendados

```javascript
describe("KipuBankV3", function() {
  
  // 1. Deployment Tests
  it("Should deploy with correct parameters")
  it("Should set owner correctly")
  it("Should initialize with zero balance")
  
  // 2. ETH Deposit Tests
  it("Should deposit ETH and receive USDC")
  it("Should reject zero ETH deposits")
  it("Should respect bankCap on ETH deposits")
  it("Should handle slippage correctly")
  
  // 3. USDC Deposit Tests
  it("Should deposit USDC directly without swap")
  it("Should update balance correctly")
  
  // 4. ERC20 Deposit Tests
  it("Should deposit DAI and receive USDC")
  it("Should revert if no pair exists")
  it("Should revert if slippage too high")
  
  // 5. Withdraw Tests
  it("Should withdraw USDC correctly")
  it("Should revert on insufficient balance")
  it("Should update totalBankBalance correctly")
  
  // 6. Bank Cap Tests
  it("Should respect bankCap strictly")
  it("Should allow deposits up to cap")
  it("Should revert when exceeding cap")
  
  // 7. View Functions Tests
  it("Should return correct balance")
  it("Should check pair existence correctly")
  it("Should estimate output correctly")
  
  // 8. Security Tests
  it("Should prevent reentrancy attacks")
  it("Should handle token transfer failures")
  it("Should protect against front-running")
  
  // 9. Edge Cases
  it("Should handle tokens with different decimals")
  it("Should handle very small amounts")
  it("Should handle maximum amounts")
});
```

### Testnet Deployment Checklist

- [ ] Deploy en Sepolia/Goerli
- [ ] Verificar contrato en Etherscan
- [ ] Depositar ETH de testnet
- [ ] Depositar USDC de testnet
- [ ] Depositar otro token (DAI, WETH)
- [ ] Retirar USDC
- [ ] Verificar estadísticas
- [ ] Probar límite del bankCap
- [ ] Verificar eventos emitidos

---

## 📊 Comparación de Versiones

| Característica | V2 (Original) | V3 (Con Uniswap) |
|----------------|---------------|------------------|
| **Tokens Soportados** | Lista fija (ETH, USDC) | Cualquier token con par |
| **Sistema de Precios** | Chainlink Oracles | Uniswap V2 AMM |
| **Balance Interno** | Multi-token | Solo USDC |
| **Complejidad Storage** | `mapping(user => mapping(token => amount))` | `mapping(user => amount)` |
| **Costo Gas (Depósito)** | ~60k (directo) | ~60k USDC, ~200k otros |
| **Costo Gas (Retiro)** | ~55k | ~45k |
| **Retiros** | En token original | Solo USDC |
| **Swaps** | No | Automático |
| **Flexibilidad** | Baja | Alta |
| **Dependencias** | Chainlink | Uniswap V2 |
| **Complexity** | Media | Media-Alta |

---

## 🎓 Conceptos Aprendidos del Curso

### 1. **Patrón Checks-Effects-Interactions**

Implementado en todas las funciones críticas para prevenir reentrancy:

```solidity
function withdraw(uint256 amount) external nonReentrant {
    // ✅ CHECKS - Validaciones
    if (amount == 0) revert KipuBank_ZeroAmount();
    uint256 userBalance = balances[msg.sender];
    if (amount > userBalance) revert KipuBank_InsufficientBalance(amount, userBalance);
    
    // ✅ EFFECTS - Cambios de estado
    unchecked {
        balances[msg.sender] = userBalance - amount;
        totalBankBalanceUSDC -= amount;
        userWithdrawalCount[msg.sender] += 1;
        totalWithdrawalsCount += 1;
    }
    
    // ✅ INTERACTIONS - Llamadas externas
    IERC20(USDC).safeTransfer(msg.sender, amount);
    
    emit WithdrawalMade(msg.sender, amount);
}
```

### 2. **SafeERC20 Library**

Uso de `SafeERC20` para manejar tokens que no siguen el estándar ERC20 estrictamente:

```solidity
using SafeERC20 for IERC20;

// Maneja tokens que:
// - No retornan bool
// - Tienen lógica custom en transfer
// - Pueden fallar silenciosamente
IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
IERC20(token).safeIncreaseAllowance(address(uniswapRouter), amount);
```

### 3. **ReentrancyGuard**

Protección contra ataques de reentrancia usando el modifier de OpenZeppelin:

```solidity
contract KipuBankV3 is Ownable, ReentrancyGuard {
    function depositETH() external payable nonReentrant {
        // Esta función no puede ser llamada recursivamente
    }
}
```

### 4. **Custom Errors (Gas Optimization)**

Uso de custom errors en lugar de `require` con strings:

```solidity
// ❌ Antiguo (consume más gas)
require(amount > 0, "Amount must be greater than zero");

// ✅ Nuevo (gas optimizado)
error KipuBank_ZeroAmount();
if (amount == 0) revert KipuBank_ZeroAmount();
```

**Ahorro**: ~50 gas por error

### 5. **Unchecked Arithmetic**

Uso de `unchecked` cuando sabemos que no hay overflow:

```solidity
unchecked {
    balances[msg.sender] += amount;  // Ya verificamos que no excede bankCap
    userDepositCount[msg.sender] += 1;  // Imposible overflow en práctica
    totalDepositsCount += 1;
}
```

### 6. **Immutable Variables**

Variables que se asignan una vez en el constructor y nunca cambian:

```solidity
address public immutable USDC;
IUniswapV2Router02 public immutable uniswapRouter;
uint256 public immutable bankCapUSD;

// Gas savings: ~2100 gas por lectura vs storage variable
```

### 7. **Receive y Fallback**

Manejo de ETH nativo con funciones especiales:

```solidity
receive() external payable {
    // Se ejecuta cuando recibimos ETH con data vacío
    if (msg.value == 0) revert KipuBank_ZeroAmount();
    _depositETH(msg.value);
}

fallback() external payable {
    // Se ejecuta en cualquier otra llamada con ETH
    if (msg.value > 0) {
        _depositETH(msg.value);
    }
}
```

### 8. **Integración con Protocolos Externos**

Interacción con Uniswap V2 siguiendo las mejores prácticas:

```solidity
// 1. Verificar existencia del par
address pair = uniswapFactory.getPair(token, USDC);
if (pair == address(0)) revert KipuBank_NoPairFound(token);

// 2. Calcular salida esperada
uint256[] memory amountsOut = uniswapRouter.getAmountsOut(amount, path);

// 3. Aplicar protección de slippage
uint256 minOut = (amountsOut[1] * 9500) / 10000; // 5% slippage

// 4. Ejecutar swap
uniswapRouter.swapExactTokensForTokens(
    amount,
    minOut,
    path,
    address(this),
    deadline
);
```

### 9. **Access Control con Ownable**

Sistema de permisos usando `Ownable` de OpenZeppelin:

```solidity
contract KipuBankV3 is Ownable {
    function setTokenPriceFeed(address token, address feed) 
        external 
        onlyOwner  // Solo el owner puede llamar
    {
        tokenPriceFeeds[token] = AggregatorV3Interface(feed);
        emit PriceFeedUpdated(token, feed);
    }
}
```

### 10. **Event Logging**

Emisión de eventos para tracking y debugging:

```solidity
event DepositMade(
    address indexed user,
    address indexed token,
    uint256 amountIn,
    uint256 amountUSDC
);

event SwapExecuted(
    address indexed user,
    address indexed tokenIn,
    uint256 amountIn,
    uint256 amountOut
);

// Los indexed permiten filtrar eventos eficientemente
```

### 11. **Manejo de Decimales**

Conversión correcta entre tokens con diferentes decimales:

```solidity
// USDC: 6 decimales
// ETH/DAI: 18 decimales
// Chainlink: 8 decimales

// Conversión segura
uint256 valueInUSD18 = (amount * uint256(price) * (10**(18 - priceFeedDecimals))) 
                       / (10**tokenDecimals);
```

### 12. **Factory Pattern en Uniswap**

Uso del patrón Factory para verificar pares:

```solidity
IUniswapV2Factory factory = IUniswapV2Factory(router.factory());
address pair = factory.getPair(tokenA, tokenB);

// El Factory mantiene un registro de todos los pares creados
// Evita deployar contratos duplicados
```

---

## 🚨 Problemas Conocidos y Limitaciones

### 1. **Tokens con Transfer Fees**

**Problema**: Tokens como PAXG o algunos tokens con tax.

**Limitación**: El contrato asume que la cantidad transferida es exacta.

**Impacto**: 
- Si el token tiene un fee del 2%, el usuario pierde ese 2%
- El slippage protection puede no ser suficiente

**Workaround**: 
```solidity
// Medir balance antes y después
uint256 balanceBefore = IERC20(token).balanceOf(address(this));
IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
uint256 balanceAfter = IERC20(token).balanceOf(address(this));
uint256 actualAmount = balanceAfter - balanceBefore;
```

### 2. **Flash Loan Attacks**

**Escenario**: Un atacante podría manipular el precio en Uniswap momentáneamente.

**Mitigación Actual**: 
- Slippage del 5% dificulta el ataque
- Pares con buena liquidez son más resistentes

**Mitigación Adicional Posible**:
- Usar TWAP (Time-Weighted Average Price)
- Requerir mínimo de liquidez en el par

### 3. **MEV (Maximal Extractable Value)**

**Problema**: Los swaps pueden ser front-run.

**Impacto**: 
- El usuario puede recibir menos USDC de lo esperado (dentro del 5%)
- Los bots pueden extraer valor

**Mitigaciones Posibles**:
- Usar Flashbots RPC
- Implementar commit-reveal scheme
- Aumentar deadline buffer

### 4. **Falta de Circuit Breakers**

**Problema**: No hay mecanismo de pausa en emergencias.

**Riesgo**: Si se descubre un bug, los fondos podrían estar en riesgo.

**Solución Futura**: Agregar `Pausable`:
```solidity
import "@openzeppelin/contracts/security/Pausable.sol";

contract KipuBankV3 is Ownable, ReentrancyGuard, Pausable {
    function depositETH() external payable nonReentrant whenNotPaused {
        // ...
    }
}
```

### 5. **Centralización del Owner**

**Problema**: El owner tiene control sobre price feeds.

**Riesgo**: Mínimo (price feeds no se usan en V3), pero existe el principio.

**Solución**: 
- Renunciar ownership: `renounceOwnership()`
- Transferir a multisig: `transferOwnership(multisigAddress)`
- Implementar DAO governance

### 6. **Dependencia de Uniswap V2**

**Problema**: Si Uniswap V2 tiene issues, afecta nuestro contrato.

**Ejemplos**:
- Par con liquidez muy baja
- Bug en el router
- Depreciación del protocolo

**Mitigación**: 
- Permitir depósitos directos de USDC
- En futuras versiones, soportar múltiples DEXs

### 7. **No Soporta Tokens Rebasing**

**Tokens Afectados**: stETH, aTokens, etc.

**Problema**: Su balance cambia automáticamente.

**Comportamiento**: El swap "congela" el valor en el momento.

**Solución**: Documentar claramente y rechazar estos tokens.

### 8. **Límite de Gas en Depósitos**

**Problema**: Swaps pueden consumir mucho gas en bloques congestionados.

**Impacto**: Transacciones pueden fallar por out-of-gas.

**Recomendación**: Estimar gas correctamente:
```javascript
const gasEstimate = await contract.estimateGas.depositERC20(token, amount);
const gasLimit = gasEstimate * 120n / 100n; // +20% buffer
```

---

## 📈 Métricas y KPIs

### Métricas On-Chain Disponibles

```solidity
// Globales
totalDepositsCount      // Total de depósitos realizados
totalWithdrawalsCount   // Total de retiros realizados
totalBankBalanceUSDC    // Balance total en USDC
bankCapUSD              // Límite máximo

// Por Usuario
balances[user]          // Balance del usuario en USDC
userDepositCount[user]  // Número de depósitos
userWithdrawalCount[user] // Número de retiros
```

### Dashboard Sugerido

```javascript
// Script para obtener métricas
const metrics = {
    totalValueLocked: await bank.getTotalBankBalanceUSDC(),
    utilizationRate: (totalValueLocked / bankCapUSD) * 100,
    totalUsers: await countUniqueUsers(),
    averageBalance: totalValueLocked / totalUsers,
    totalDeposits: await bank.totalDepositsCount(),
    totalWithdrawals: await bank.totalWithdrawalsCount(),
    netFlow: totalDeposits - totalWithdrawals
};
```

---

## 🔮 Roadmap Futuro (V4+)

### Mejoras Planeadas

1. **✨ Multi-DEX Support**
   - Integrar Uniswap V3 para mejor eficiencia
   - Soportar SushiSwap, Curve, Balancer
   - Routing inteligente para mejor precio

2. **⏸️ Circuit Breakers**
   - Implementar `Pausable`
   - Timelock en funciones admin
   - Rate limiting en depósitos grandes

3. **📊 Yield Generation**
   - Depositar USDC idle en Aave/Compound
   - Generar rendimiento para usuarios
   - Shares tokenizados (ERC4626)

4. **🎯 Dynamic Slippage**
   - Slippage configurable por usuario
   - Oracle de volatilidad para ajuste automático

5. **🔐 Multi-sig Ownership**
   - Migrar a Gnosis Safe
   - Governance con tokens
   - Descentralización progresiva

6. **🌉 Cross-Chain Support**
   - Bridge a L2s (Arbitrum, Optimism)
   - Unified liquidity pools

7. **📱 SDK y Frontend**
   - NPM package para integración
   - React hooks
   - Web app para usuarios no-técnicos

---

## 🤝 Contribuciones

### Cómo Contribuir

1. Fork el repositorio
2. Crea una rama: `git checkout -b feature/nueva-funcionalidad`
3. Commit cambios: `git commit -am 'Add nueva funcionalidad'`
4. Push a la rama: `git push origin feature/nueva-funcionalidad`
5. Crea un Pull Request

### Áreas de Contribución

- 🧪 **Testing**: Agregar más test cases
- 📚 **Documentación**: Mejorar ejemplos y tutoriales
- 🔒 **Seguridad**: Identificar vulnerabilidades
- ⚡ **Optimización**: Reducir gas costs
- 🎨 **Frontend**: Crear interfaces de usuario

---

## 📞 Soporte y Contacto

### Recursos

- **Documentación**: Este README
- **Código Fuente**: [GitHub Repository]
- **Auditorías**: [Pending]
- **Bug Bounty**: [To be announced]

### Comunidad

- **Discord**: [Community Server]
- **Twitter**: [@KipuBank]
- **Telegram**: [Support Group]

### Reportar Bugs

Para reportar vulnerabilidades de seguridad:
- **Email**: security@kipubank.xyz
- **KeyBase**: [Encrypted Communications]

Para bugs no-críticos:
- Abrir un Issue en GitHub
- Usar la etiqueta apropiada (bug, enhancement, question)

---

## 📜 Licencia

Este proyecto está licenciado bajo la licencia MIT.

```
MIT License

Copyright (c) 2024 KipuBank

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 🙏 Agradecimientos

- **OpenZeppelin**: Por los contratos seguros y bien auditados
- **Uniswap**: Por el protocolo de intercambio descentralizado
- **Chainlink**: Por los oráculos de precios confiables (V2)
- **Comunidad Ethereum**: Por el ecosistema y herramientas

---

## 📊 Resumen Ejecutivo

### TL;DR

**KipuBankV3** es una bóveda multi-token que:

✅ Acepta ETH y cualquier ERC20 con liquidez en Uniswap V2  
✅ Convierte automáticamente todo a USDC  
✅ Mantiene un límite global configurable  
✅ Protege contra slippage (5%) y reentrancy  
✅ Optimizado para gas y seguridad  

**Mejoras vs V2:**
- 🔄 Swaps automáticos via Uniswap
- 📦 Balance simplificado (solo USDC)
- 🎯 Soporte para cientos de tokens
- 🔒 Seguridad mejorada

**Trade-offs Principales:**
- ⚠️ Mayor costo de gas en depósitos
- ⚠️ Retiros solo en USDC
- ⚠️ Dependencia de Uniswap V2

**Próximos Pasos:**
1. ✅ Auditoría profesional
2. ✅ Deploy en testnet
3. ✅ Testing exhaustivo
4. ✅ Mainnet deployment
5. ✅ Integración con frontend

---

## 🎓 Para Estudiantes

Este proyecto demuestra:

- ✅ **Integración con protocolos DeFi** (Uniswap V2)
- ✅ **Patrones de seguridad** (CEI, ReentrancyGuard)
- ✅ **Optimización de gas** (immutable, unchecked, custom errors)
- ✅ **Manejo de tokens** (SafeERC20, decimales)
- ✅ **Control de acceso** (Ownable)
- ✅ **Event logging** para tracking
- ✅ **Arquitectura modular** y escalable

**Conceptos clave del curso aplicados:**
1. Smart Contract Security
2. DeFi Protocol Integration
3. Gas Optimization Techniques
4. Token Standards (ERC20)
5. Access Control Patterns
6. Testing Best Practices

---

**Versión**: 3.0.0  
**Última Actualización**: Noviembre 2024  
**Autor**: JuanCruzSaladino / Gemini / Claude  
**Estado**: 🟡 En Desarrollo - Requiere Auditoría

---

*Construyendo el futuro de las finanzas descentralizadas, un contrato a la vez.* 🚀