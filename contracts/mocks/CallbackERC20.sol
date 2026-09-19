// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ITokenTransferReceiver {
    function onTokenTransfer(address from, uint256 amount) external;
}

contract CallbackERC20 is ERC20 {
    bool public callbackEnabled = true;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setCallbackEnabled(bool enabled) external {
        callbackEnabled = enabled;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        _notifyReceiver(_msgSender(), to, amount);
        return success;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);
        _notifyReceiver(from, to, amount);
        return success;
    }

    function _notifyReceiver(address from, address to, uint256 amount) internal {
        if (callbackEnabled && to.code.length > 0) {
            try ITokenTransferReceiver(to).onTokenTransfer(from, amount) {} catch {}
        }
    }
}
