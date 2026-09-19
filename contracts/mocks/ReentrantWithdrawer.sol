// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFarmForAttack {
    function deposit(uint256 poolId, uint256 tierId, uint256 amount) external;
    function withdraw(uint256 poolId, uint256 positionId, uint256 amount) external;
    function positionsLength(uint256 poolId, address user) external view returns (uint256);
}

interface ICallbackTokenReceiver {
    function onTokenTransfer(address from, uint256 amount) external;
}

contract ReentrantWithdrawer is ICallbackTokenReceiver {
    IFarmForAttack public immutable farm;
    IERC20 public immutable lpToken;
    uint256 public attackPoolId;
    uint256 public attackPositionId;
    uint256 public attackAmount;
    bool public attackAttempted;
    bool public reentrancySucceeded;

    constructor(address farmAddress, address lpTokenAddress) {
        farm = IFarmForAttack(farmAddress);
        lpToken = IERC20(lpTokenAddress);
    }

    function deposit(uint256 poolId, uint256 tierId, uint256 amount) external {
        lpToken.approve(address(farm), amount);
        farm.deposit(poolId, tierId, amount);
    }

    function attackWithdraw(uint256 poolId, uint256 positionId, uint256 amount) external {
        attackPoolId = poolId;
        attackPositionId = positionId;
        attackAmount = amount;
        attackAttempted = false;
        reentrancySucceeded = false;
        farm.withdraw(poolId, positionId, amount);
    }

    function onTokenTransfer(address, uint256) external override {
        if (msg.sender != address(lpToken) || attackAttempted) {
            return;
        }

        attackAttempted = true;
        (bool ok,) = address(farm).call(
            abi.encodeCall(IFarmForAttack.withdraw, (attackPoolId, attackPositionId, attackAmount))
        );
        reentrancySucceeded = ok;
    }
}
