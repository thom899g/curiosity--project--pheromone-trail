// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract PheromoneQueen is Initializable, UUPSUpgradeable, Ownable {
    // ========== STATE VARIABLES ==========
    IERC20 public immutable USDC;
    address public constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    
    uint256 public reserveCapital; // Base capital that should not be risked
    uint256 public profitAccumulated;
    
    // Worker management
    address[] public activeWorkers;
    mapping(address => bool) public isWorker;
    
    // Strategy parameters
    uint256 public constant MIN_DEPLOYMENT_CAPITAL = 100 * 10**6; // 100 USDC (6 decimals)
    uint256 public constant MAX_PRICE_DEVIATION = 5; // 0.5% in basis points
    uint256 public constant POSITION_SIZE = 150 * 10**6; // 150 USDC per Worker
    
    // Oracles
    AggregatorV3Interface internal priceFeed;
    
    // Emergency controls
    bool public tradingPaused;
    uint256 public pauseDuration;
    
    // ========== EVENTS ==========
    event WorkerDeployed(address indexed worker, address pool, uint256 amount);
    event WorkerRetired(address indexed worker, uint256 profit);
    event CapitalReallocated(uint256 newReserve);
    event TradingPaused(string reason);
    event TradingResumed();
    
    // ========== MODIFIERS ==========
    modifier onlySelf() {
        require(msg.sender == address(this), "Queen: caller is not self");
        _;
    }
    
    modifier whenNotPaused() {
        require(!tradingPaused, "Queen: trading paused");
        _;
    }
    
    // ========== INITIALIZER ==========
    function initialize(
        address _usdc,
        address _priceFeed,
        address _initialOwner
    ) external initializer {
        require(_usdc != address(0), "Queen: invalid USDC");
        require(_priceFeed != address(0), "Queen: invalid price feed");
        
        USDC = IERC20(_usdc);
        priceFeed = AggregatorV3Interface(_priceFeed);
        reserveCapital = 0;
        profitAccumulated = 0;
        tradingPaused = false;
        
        __Ownable_init();
        __UUPSUpgradeable_init();
        transferOwnership(_initialOwner);
    }
    
    // ========== CORE LOGIC ==========
    function deployWorker(
        address pool,
        int24 tickLower,
        int24 tickUpper
    ) external whenNotPaused returns (address) {
        // Price sanity check
        (uint256 currentPrice, ) = _getOraclePrice();
        (uint256 poolPrice, ) = _getPoolPrice(pool);
        uint256 deviation = _calculateDeviation(currentPrice, poolPrice);
        
        require(deviation <= MAX_PRICE_DEVIATION, "Queen: price deviation too high");
        require(USDC.balanceOf(address(this)) - reserveCapital >= POSITION_SIZE, "Queen: insufficient capital");
        
        // Deploy Worker contract
        PheromoneWorker worker = new PheromoneWorker(
            address(USDC),
            pool,
            tickLower,
            tickUpper,
            POSITION_SIZE
        );
        
        // Transfer capital to Worker
        USDC.transfer(address(worker), POSITION_SIZE);
        
        // Activate position
        worker.activate();
        
        // Register Worker
        activeWorkers.push(address(worker));
        isWorker[address(worker)] = true;
        
        emit WorkerDeployed(address(worker), pool, POSITION_SIZE);
        return address(worker);
    }
    
    function retireWorker(address worker) external {
        require(isWorker[worker], "Queen: not a worker");
        require(PheromoneWorker(worker).isActive() == false, "Queen: worker still active");
        
        // Calculate profit
        uint256 initialCapital = POSITION_SIZE;
        uint256 returnedCapital = USDC.balanceOf(worker);
        int256 profit = int256(returnedCapital) - int256(initialCapital);
        
        // Transfer remaining funds
        USDC.transferFrom(worker, address(this), returnedCapital);
        
        // Remove from active workers
        for (uint256 i = 0; i < activeWorkers.length; i++) {
            if (activeWorkers[i] == worker) {
                activeWorkers[i] = activeWorkers[activeWorkers.length - 1];
                activeWorkers.pop();
                break;
            }
        }
        
        isWorker[worker] = false;
        
        if (profit > 0) {
            profitAccumulated += uint256(profit);
            emit WorkerRetired(worker, uint256(profit));
        } else {
            emit WorkerRetired(worker, 0);
        }
        
        // Self-destruct Worker
        PheromoneWorker(worker).selfDestruct();
    }
    
    function reinvestProfits() external onlySelf {
        uint256 availableCapital = USDC.balanceOf(address(this)) - reserveCapital;
        
        if (availableCapital > MIN_DEPLOYMENT_CAPITAL) {
            // Update reserve to lock in profits
            reserveCapital += availableCapital / 2; // Reinvest half
            emit CapitalReallocated(reserveCapital);
        }
    }
    
    // ========== ORACLE FUNCTIONS ==========
    function _getOraclePrice() internal view returns (uint256, uint256) {
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        require(price > 0, "Queen: invalid price");
        require(block.timestamp - updatedAt < 3600, "Queen: stale price");
        
        return (uint256(price), updatedAt);
    }
    
    function _getPoolPrice(address pool) internal view returns (uint256, uint256) {
        // Simplified - would integrate with Uniswap V3 pool's slot0
        // For MVP, return oracle price
        return _getOraclePrice();
    }
    
    function _calculateDeviation(uint256 price1, uint256 price2) internal pure returns (uint256) {
        if (price1 == 0 || price2 == 0) return type(uint256).max;
        
        uint256 difference = price1 > price2 ? price1 - price2 : price2 - price1;
        return (difference * 10000) / price1; // Basis points
    }
    
    // ========== EMERGENCY FUNCTIONS ==========
    function emergencyPause(string calldata reason) external onlyOwner {
        tradingPaused = true;
        pauseDuration = block.timestamp;
        emit TradingPaused(reason);
    }
    
    function resumeTrading() external onlyOwner {
        require(tradingPaused, "Queen: not paused");
        require(block.timestamp - pauseDuration > 1 hours, "Queen: cooling period");
        
        tradingPaused = false;
        emit TradingResumed();
    }
    
    function emergencyWithdraw() external onlyOwner {
        require(tradingPaused, "Queen: must pause first");
        require(block.timestamp - pauseDuration > 12 hours, "Queen: 12h timelock");
        
        uint256 balance = USDC.balanceOf(address(this));
        USDC.transfer(owner(), balance);
    }
    
    // ========== VIEW FUNCTIONS ==========
    function getActiveWorkerCount() external view returns (uint256) {
        return activeWorkers.length;
    }
    
    function getTotalCapital() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }
    
    function getAvailableCapital() external view returns (uint256) {
        return USDC.balanceOf(address(this)) - reserveCapital;
    }
    
    // ========== UUPS ==========
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}