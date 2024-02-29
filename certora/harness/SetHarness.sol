// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import "../../src/Set.sol";

contract SetHarness {

    SetStorage public setStorage;

    function insert(
        address element
    ) external returns (bool wasInserted) {
        return Set.insert(setStorage, element);
    }

    function remove(
        address element
    ) external returns (bool) {
        return Set.remove(setStorage, element);
    }

    function get(uint8 index) external view returns (address ) {
        if (index==0) return setStorage.firstElement;
        return setStorage.elements[index].value;

    }

    function contains(
        address element
    ) external view returns (bool found) {
        return Set.contains(setStorage, element);
    }


    function length(
    ) external view returns (uint8) {
        return setStorage.numElements;
    }

    function get() external view returns (address [] memory) {
        return Set.get(setStorage);
    }

    function reorder(uint8 index1, uint8 index2) external {
        Set.reorder(setStorage, index1, index2);
    }

}