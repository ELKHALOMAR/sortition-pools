pragma solidity ^0.5.10;

import "./Leaf.sol";

library Operator {
    ////////////////////////////////////////////////////////////////////////////
    // Parameters for configuration

    // How many bits a position uses per level of the tree;
    // each branch of the tree contains 2**SLOT_BITS slots.
    uint256 constant SLOT_BITS = 3;
    uint256 constant LEVELS = 7;
    ////////////////////////////////////////////////////////////////////////////

    ////////////////////////////////////////////////////////////////////////////
    // Derived constants, do not touch
    uint256 constant SLOT_COUNT = 2 ** SLOT_BITS;
    uint256 constant SLOT_WIDTH = 256 / SLOT_COUNT;
    uint256 constant SLOT_MAX = (2 ** SLOT_WIDTH) - 1;

    uint256 constant WEIGHT_WIDTH = SLOT_WIDTH;
    uint256 constant WEIGHT_MAX = SLOT_MAX;

    uint256 constant START_INDEX_WIDTH = WEIGHT_WIDTH;
    uint256 constant START_INDEX_MAX = WEIGHT_MAX;
    uint256 constant START_INDEX_SHIFT = WEIGHT_WIDTH;

    uint256 constant POSITION_WIDTH = SLOT_BITS * LEVELS;
    uint256 constant POSITION_MAX = (2 ** POSITION_WIDTH) - 1;
    uint256 constant POSITION_SHIFT = START_INDEX_SHIFT + START_INDEX_WIDTH;

    uint256 constant DELETE_FLAG_SHIFT = POSITION_SHIFT + POSITION_WIDTH;
    uint256 constant DELETE_FLAG = 1 << DELETE_FLAG_SHIFT;
    ////////////////////////////////////////////////////////////////////////////

    // Operator stores information about a selected operator
    // inside a single uint256 in a manner similar to Leaf
    // but optimized for use within group selection
    //
    // The information stored consists of:
    // - weight
    // - starting index
    // - leaf position
    // - whether the operator is to be deleted or only skipped
    // - operator address

    function make(
        address operator,
        bool toDelete,
        uint256 position,
        uint256 startingIndex,
        uint256 weight
    ) internal pure returns (uint256) {
        uint256 op = uint256(bytes32(bytes20(operator)));
        uint256 del = 0;
        if (toDelete) {del = DELETE_FLAG;}
        uint256 pos = (position & POSITION_MAX) << POSITION_SHIFT;
        uint256 idx = (startingIndex & START_INDEX_MAX) << START_INDEX_SHIFT;
        uint256 wt = weight & WEIGHT_MAX;
        return (op | del | pos | idx | wt);
    }

    function opAddress(uint256 op) internal pure returns (address) {
        return Leaf.operator(op);
    }

    function opWeight(uint256 op) internal pure returns (uint256) {
        return (op & WEIGHT_MAX);
    }

    // Return whether the delete flag is set
    function needsDeleting(uint256 a) internal pure returns (bool) {
        return ((a & DELETE_FLAG) > 0);
    }

    function setDeleteFlag(uint256 a) internal pure returns (uint256) {
        return (a | DELETE_FLAG);
    }

    // Return the starting index of the operator
    function index(uint256 a) internal pure returns (uint256) {
        return ((a >> WEIGHT_WIDTH) & START_INDEX_MAX);
    }

    function position(uint256 op) internal pure returns (uint256) {
        return ((op >> POSITION_SHIFT) & POSITION_MAX);
    }

    function setIndex(uint256 op, uint256 i) internal pure returns (uint256) {
        uint256 shiftedIndex = ((i & START_INDEX_MAX) << WEIGHT_WIDTH);
        return op & (~(START_INDEX_MAX << WEIGHT_WIDTH)) | shiftedIndex;
    }

    function insert(uint256[] memory operators, uint256 operator)
        internal
        returns (uint256) // The last operator left outside the array
    {
        uint256 tempOperator = operator;
        for (uint256 i = 0; i < operators.length; i++) {
            uint256 thisOperator = operators[i];
            if (index(tempOperator) < index(thisOperator)) {
                operators[i] = tempOperator;
                tempOperator = thisOperator;
            }
        }
        return tempOperator;
    }

    function skip(uint256 truncatedIndex, uint256[] memory operators)
        internal
        pure
        returns (uint256 mappedIndex)
    {
        mappedIndex = truncatedIndex;
        for (uint256 i = 0; i < operators.length; i++) {
            uint256 operator = operators[i];
            // If the index is greater than the starting index of the `i`th leaf,
            // we need to skip that leaf.
            if (mappedIndex >= index(operator)) {
                // Add the weight of this previous leaf to the index,
                // ensuring that we skip the leaf.
                mappedIndex += Leaf.weight(operator);
            } else {
                break;
            }
        }
        return mappedIndex;
    }
}
