// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract PheromoneWorker {
    using SafeERC20 for IERC20;
    
    // ========== STATE VARIABLES ==========
    IERC20 public immutable USDC;
    address public immutable pool;
    address public queen;
    
    int24 public tickLower;
    int24 public tickUpper;
    uint256 public positionSize;
    
    bool public isActive;
    bool public isFilled;
    
    // ========== EVENTS ==========
    event PositionActivated(address indexed worker, uint256 amount);
    event PositionFilled(address indexed worker, uint256 amountOut);
    event PositionCancelled(address indexed worker, string reason);
    
    // ========== MODIFIERS ==========
    modifier onlyQueen() {
        require(msg.sender == queen, "Worker: caller is not queen");
        _;
    }
    
    // ========== CONSTRUCTOR ==========
    constructor(
        address _usdc,
        address _pool,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 _positionSize
    ) {
        USDC = IERC20(_usdc);
        pool = _pool;
        tickLower = _tickLower;
        tickUpper = _tickUpper;
        positionSize = _positionSize;
        queen = msg.sender;
        isActive = false;
        isFilled = false;
    }
    
    // ========== CORE FUNCTIONS ==========
    function activate() external onlyQueen {
        require(!isActive, "Worker: already active");
        
        // Approve Uniswap V3 pool manager
        USDC.safeApprove(pool, positionSize);
        
        // In production: Call Uniswap V3 NonfungiblePositionManager.mint()
        // For MVP: Simulate activation
        
        isActive = true;
        emit PositionActivated(address(this), positionSize);
    }
    
    function reportFill(uint256 amountOut) external onlyQueen {
        require(isActive, "Worker: not active");
        require(!isFilled, "Worker: already filled");
        
        isFilled = true;
        isActive = false;
        emit PositionFilled(address(this), amountOut);
    }
    
    function cancelPosition(string calldata reason) external onlyQueen {
        require(isActive, "Worker: not active");
        
        // Revoke approval
        USDC.safeApprove(pool, 0);
        
        isActive = false;
        emit PositionCancelled(address(this), reason);
    }
    
    function selfDestruct() external onlyQueen {
        require(!isActive, "Worker: cannot destroy active");
        
        // Transfer any remaining USDC back to Queen
        uint256 balance = USDC.balanceOf(address(this));
        if (balance > 0) {
            USDC.safeTransfer(queen, balance);
        }
        
        selfdestruct(payable(queen));
    }
    
    // ========== VIEW FUNCTIONS ==========
    function getPositionValue() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }
}