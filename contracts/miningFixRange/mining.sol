// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.4;

// Uncomment if needed.
// import "hardhat/console.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../multicall.sol";

/// @title Simple math library for Max and Min.
library Math {
    function max(int24 a, int24 b) internal pure returns (int24) {
        return a >= b ? a : b;
    }

    function min(int24 a, int24 b) internal pure returns (int24) {
        return a < b ? a : b;
    }
}

/// @title Uniswap V3 Nonfungible Position Manager Interface
interface PositionManagerV3 {
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function ownerOf(uint256 tokenId) external view returns (address);

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;
}

/// @title Uniswap V3 Liquidity Mining Main Contract
contract Mining is Ownable, Multicall, ReentrancyGuard {
    using Math for int24;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    struct PoolInfo {
        address token0;
        address token1;
        uint24 fee;
    }

    PoolInfo public rewardPool;

    /// @dev Contract of the reward erc20 token.
    IERC20 rewardToken;

    /// @dev Contract of the uniV3 Nonfungible Position Manager.
    PositionManagerV3 uniV3NFTManager;

    /// @dev The reward range of this mining contract.
    int24 rewardUpperTick;
    int24 rewardLowerTick;

    /// @dev Accumulated Reward Tokens per share, times 1e128.
    uint256 accRewardPerShare;
    
    /// @dev Last block number that the accRewardRerShare is touched.
    uint256 lastTouchBlock;

    /// @dev Reward amount for each block.
    uint256 rewardPerBlock;

    /// @dev Current total virtual liquidity.
    uint256 totalVLiquidity;

    /// @dev The block number when NFT mining rewards starts/ends.
    uint256 startBlock;
    uint256 endBlock;

    /// @dev Store the owner of the NFT token
    mapping(uint256 => address) public owners;
    /// @dev The inverse mapping of owners.
    mapping(address => EnumerableSet.UintSet) private tokenIds;

    /// @dev Record the status for a certain token for the last touched time.
    struct TokenStatus {
        uint256 vLiquidity;
        uint256 lastTouchBlock;
        uint256 lastTouchAccRewardPerShare;
    }

    mapping(uint256 => TokenStatus) tokenStatus;


    /// @dev 2 << 128
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;

    // Events
    event Deposit(address indexed user, uint256 tokenId);
    event Withdraw(address indexed user, uint256 tokenId);
    event WithdrawNoReward(address indexed user, uint256 tokenId);
    event CollectReward(address indexed user, uint256 tokenId, uint256 amount);
    event ModifyEndBlock(uint256 endBlock);
    event ModifyRewardPerBlock(uint256 rewardPerBlock);

    constructor(
        address _uniV3NFTManager,
        address token0,
        address token1,
        uint24 fee,
        address _rewardToken,
        uint256 _rewardPerBlock,
        int24 _rewardUpperTick,
        int24 _rewardLowerTick,
        uint256 _startBlock,
        uint256 _endBlock
    ) {
        uniV3NFTManager = PositionManagerV3(_uniV3NFTManager);

        rewardToken = IERC20(_rewardToken);

        require(token0 < token1, "TOKEN0 < TOKEN1 NOT MATCH");
        rewardPool.token0 = token0;
        rewardPool.token1 = token1;
        rewardPool.fee = fee;

        rewardPerBlock = _rewardPerBlock;

        rewardUpperTick = _rewardUpperTick;
        rewardLowerTick = _rewardLowerTick;

        startBlock = _startBlock;
        endBlock = _endBlock;

        lastTouchBlock = startBlock;
        accRewardPerShare = 0;
        // set 1 as the initial value to prevent the divided by zero error.
        totalVLiquidity = 1;
    }

    /// @notice Get the overall info for the mining contract.
    function getMiningContractInfo()
        external
        view
        returns (
            address token0_,
            address token1_,
            uint24 fee_,
            address rewardToken_,
            int24 rewardUpperTick_,
            int24 rewardLowerTick_,
            uint256 accRewardPerShare_,
            uint256 lastTouchBlock_,
            uint256 rewardPerBlock_,
            uint256 totalVLiquidity_,
            uint256 startBlock_,
            uint256 endBlock_
        )
    {
        return (
            rewardPool.token0,
            rewardPool.token1,
            rewardPool.fee,
            address(rewardToken),
            rewardUpperTick,
            rewardLowerTick,
            accRewardPerShare,
            lastTouchBlock,
            rewardPerBlock,
            totalVLiquidity,
            startBlock,
            endBlock
        );
    }

    /// @notice Compute the virtual liquidity from a position's parameters.
    /// @param tickLower The lower tick of a position.
    /// @param tickUpper The upper tick of a position.
    /// @param liquidity The liquidity of a a position.
    /// @dev vLiquidity = liquidity * validRange^2 / 1e6, where the validRange is the tick amount of the 
    /// intersection between the position and the reward range. 
    /// We divided it by 1e6 to keep vLiquidity smaller than 1e128. This is safe since liqudity is usually a large number.
    function _getVLiquidityForNFT(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal view returns (uint256 vLiquidity) {
        // liquidity is roughly equals to sqrt(amountX*amountY)
        require(liquidity >= 1e6, "LIQUIDITY TOO SMALL");
        uint256 validRange = uint24(
            Math.max(
                Math.min(rewardUpperTick, tickUpper) - Math.max(rewardLowerTick, tickLower),
                0
            )
        );
        vLiquidity = validRange * validRange * uint256(liquidity) / 1e6;
        return vLiquidity;
    }

    /// @notice Update a token status when touched.
    function _updateTokenStatus(uint256 tokenId, uint256 vLiquidity) internal {
        TokenStatus storage t = tokenStatus[tokenId];
        if (vLiquidity > 0) {
            t.vLiquidity = vLiquidity;
        }
        t.lastTouchBlock = lastTouchBlock;
        t.lastTouchAccRewardPerShare = accRewardPerShare;
    }

    /// @notice Update reward variables to be up-to-date.
    function _updateVLiquidity(uint256 vLiquidity, bool isAdd) internal {
        if (isAdd) {
            totalVLiquidity = totalVLiquidity + vLiquidity;
        } else {
            totalVLiquidity = totalVLiquidity - vLiquidity;
        }

        // Q128 is enough for 10^5 * 10^5 * 10^18 * 10^10
        require(totalVLiquidity <= Q128, "TOO MUCH LIQUIDITY STAKED");
    }

    /// @notice Update the global status.
    function _updateGlobalStatus() internal {
        if (lastTouchBlock >= block.number) {
            return;
        }

        // acc(T) = acc(T-N) + N * R * 1 / sum(L)
        uint256 multiplier = _getMultiplier(lastTouchBlock, block.number);
        uint256 tokenReward = multiplier * rewardPerBlock;
        accRewardPerShare = accRewardPerShare + ((tokenReward * Q128) / totalVLiquidity);
        lastTouchBlock = block.number;
    }

    /// @notice Return reward multiplier over the given _from to _to block.
    /// @param _from The start block.
    /// @param _to The end block.
    function _getMultiplier(uint256 _from, uint256 _to)
        internal
        view
        returns (uint256)
    {
        if (_to <= endBlock) {
            return _to - _from;
        } else if (_from >= endBlock) {
            return 0;
        } else {
            return endBlock - _from;
        }
    }

    /// @notice Deposit a single position.
    /// @param tokenId The related position id.
    function deposit(uint256 tokenId) external returns (uint256 vLiquidity) {
        address owner = uniV3NFTManager.ownerOf(tokenId);
        require(owner == msg.sender, "NOT OWNER");

        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            ,
            ,
            ,

        ) = uniV3NFTManager.positions(tokenId);

        // alternatively we can compute the pool address with tokens and fee and compare the address directly
        require(token0 == rewardPool.token0, "TOEKN0 NOT MATCH");
        require(token1 == rewardPool.token1, "TOKEN1 NOT MATCH");
        require(fee == rewardPool.fee, "FEE NOT MATCH");

        // require the NFT token has interaction with [rewardLowerTick, rewardUpperTick]
        vLiquidity = _getVLiquidityForNFT(tickLower, tickUpper, liquidity);
        require(vLiquidity > 0, "INVALID TOKEN");

        uniV3NFTManager.transferFrom(msg.sender, address(this), tokenId);
        owners[tokenId] = msg.sender;
        bool res = tokenIds[msg.sender].add(tokenId);
        require(res);

        // the execution order for the next three lines is crutial
        _updateGlobalStatus();
        _updateVLiquidity(vLiquidity, true);
        _updateTokenStatus(tokenId, vLiquidity);

        emit Deposit(msg.sender, tokenId);
        return vLiquidity;
    }

    /// @notice Widthdraw a single position.
    /// @param tokenId The related position id.
    function withdraw(uint256 tokenId) external {
        require(owners[tokenId] == msg.sender, "NOT OWNER OR NOT EXIST");

        collectReward(tokenId);
        uint256 vLiquidity = tokenStatus[tokenId].vLiquidity;
        _updateVLiquidity(vLiquidity, false);

        uniV3NFTManager.safeTransferFrom(address(this), msg.sender, tokenId);
        owners[tokenId] = address(0);
        bool res = tokenIds[msg.sender].remove(tokenId);
        require(res);

        emit Withdraw(msg.sender, tokenId);
    }

    /// @notice Collect pending reward for a single position.
    /// @param tokenId The related position id.
    function collectReward(uint256 tokenId) public nonReentrant {
        require(owners[tokenId] == msg.sender, "NOT OWNER or NOT EXIST");
        TokenStatus memory t = tokenStatus[tokenId];

        _updateGlobalStatus();

        // l * (currentAcc - lastAcc)
        uint256 _reward = (t.vLiquidity * (accRewardPerShare - t.lastTouchAccRewardPerShare)) / Q128;
        if (_reward > 0) {
            rewardToken.safeTransferFrom(owner(), msg.sender, _reward);
        }
        _updateTokenStatus(tokenId, 0);

        emit CollectReward(msg.sender, tokenId, _reward);
    }

    /// @notice Collect all pending rewards.
    function collectRewards() external {
        EnumerableSet.UintSet storage ids = tokenIds[msg.sender];
        for (uint256 i = 0; i < ids.length(); i++) {
            collectReward(ids.at(i));
        }
    }

    /// @notice View function to get position ids staked here for an user.
    /// @param _user The related address.
    function getTokenIds(address _user)
        external
        view
        returns (uint256[] memory)
    {
        EnumerableSet.UintSet storage ids = tokenIds[_user];
        // push could not be used in memory array
        // we set the tokenIdList into a fixed-length array rather than dynamic
        uint256[] memory tokenIdList = new uint256[](ids.length());
        for (uint256 i = 0; i < ids.length(); i++) {
            tokenIdList[i] = ids.at(i);
        }
        return tokenIdList;
    }

    /// @notice View function to see pending Reward for a single position.
    /// @param tokenId The related position id.
    function pendingReward(uint256 tokenId) external view returns (uint256) {
        TokenStatus memory t = tokenStatus[tokenId];
        uint256 multiplier = _getMultiplier(lastTouchBlock, block.number);
        uint256 tokenReward = multiplier * rewardPerBlock;
        uint256 rewardPerShare = accRewardPerShare + (tokenReward * Q128) / totalVLiquidity;
        // l * (currentAcc - lastAcc)
        uint256 _reward = (t.vLiquidity * (rewardPerShare - t.lastTouchAccRewardPerShare)) / Q128;
        return _reward;
    }

    /// @notice View function to see pending Rewards for an address.
    /// @param _user The related address.
    function pendingRewards(address _user) external view returns (uint256) {
        uint256 multiplier = _getMultiplier(lastTouchBlock, block.number);
        uint256 tokenReward = multiplier * rewardPerBlock;
        uint256 rewardPerShare = accRewardPerShare + (tokenReward * Q128) / totalVLiquidity;
        uint256 _reward = 0;

        for (uint256 i = 0; i < tokenIds[_user].length(); i++) {
            TokenStatus memory t = tokenStatus[tokenIds[_user].at(i)];
            _reward += (t.vLiquidity * (rewardPerShare - t.lastTouchAccRewardPerShare)) / Q128;
        }
        return _reward;
    }

    /// @notice Widthdraw a single position without claiming rewards.
    /// @param tokenId The related position id.
    function withdrawNoReward(uint256 tokenId) public {
        require(owners[tokenId] == msg.sender, "NOT OWNER OR NOT EXIST");

        // The collecting procedure is commenced out.
        // collectReward(tokenId);
        // The global status needs update since the vLiquidity is changed after withdraw.
        _updateGlobalStatus();

        uint256 vLiquidity = tokenStatus[tokenId].vLiquidity;
        _updateVLiquidity(vLiquidity, false);

        uniV3NFTManager.safeTransferFrom(address(this), msg.sender, tokenId);
        owners[tokenId] = address(0);
        tokenIds[msg.sender].remove(tokenId);

        emit WithdrawNoReward(msg.sender, tokenId);
    }


    // Control fuctions for the contract owner and operators.

    /// @notice If something goes wrong, we can send back user's nft.
    /// @param tokenId The related position id.
    function emergenceWithdraw(uint256 tokenId) external onlyOwner {
        uniV3NFTManager.safeTransferFrom(address(this), owners[tokenId], tokenId);
    }

    /// @notice Set new reward end block.
    /// @param _endBlock New end block.
    function modifyEndBlock(uint256 _endBlock) external onlyOwner {
        _updateGlobalStatus();
        endBlock = _endBlock;
        emit ModifyEndBlock(endBlock);
    }

    /// @notice Set new reward per block.
    /// @param _rewardPerBlock New end block.
    function modifyRewardPerBlock(uint _rewardPerBlock) external onlyOwner {
        _updateGlobalStatus();
        rewardPerBlock = _rewardPerBlock;
        emit ModifyRewardPerBlock(rewardPerBlock);
    }

}
