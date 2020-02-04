pragma solidity ^0.5.10;

import "./IBondingContract.sol";
import "./Sortition.sol";
import "./RNG.sol";

/// @title Bonded Sortition Pool
/// @notice A logarithmic data structure used to store the pool of eligible
/// operators weighted by their stakes. It allows to select a group of operators
/// based on the provided pseudo-random seed and bonding requirements.
contract BondedSortitionPool is Sortition {
    function selectSetGroupB(
        uint256 groupSize,
        bytes32 seed,
        uint256 bondSize,
        IBondingContract bondingContract
    ) public returns (address[] memory) {
        uint256 operatorsRemaining = operatorsInPool();

        address[] memory selected = new address[](groupSize);
        uint256 nSelected = 0;

        uint256 idx;
        bytes32 rngState = seed;

        uint256 totalWeight = root.sumWeight();

        uint256 leafOrWeight;
        address op;
        bool duplicate;

        while (nSelected < groupSize) {
            require(
                operatorsRemaining >= groupSize,
                "Not enough operators in pool"
            );

            (idx, rngState) = RNG.getIndex(totalWeight, rngState);
            /* (idx, rngState) = RNG.getIndex(root.sumWeight(), rngState); */

            leafOrWeight = leaves[pickWeightedLeaf(idx)];
            op = leafOrWeight.operator();
            // XXX: awful but saves a slot
            leafOrWeight = leafOrWeight.weight();

            duplicate = false;
            for (uint256 i = 0; i < nSelected; i++) {
                if (op == selected[i]) {
                    duplicate = true;
                    break;
                }
            }

            if (!duplicate) {
                if (bondingContract.isEligible(op, leafOrWeight, bondSize)) {
                    selected[nSelected] = op;
                    nSelected += 1;
                } else {
                    removeOperator(op);
                    totalWeight -= leafOrWeight;
                    operatorsRemaining -= 1;
                }
            }
        }

        return selected;
    }

    /// @notice Selects a new group of operators of the provided size based on
    /// the provided pseudo-random seed and bonding requirements. All operators
    /// in the group are unique.
    ///
    /// If there are not enough operators in a pool to form a group or not
    /// enough operators are eligible for work selection given the bonding
    /// requirements, the function fails.
    /// @param groupSize Size of the requested group
    /// @param seed Pseudo-random number used to select operators to group
    /// @param bondSize Size of the requested bond per operator
    /// @param bondingContract 3rd party contract checking bond requirements
    function selectSetGroup(
        uint256 groupSize,
        bytes32 seed,
        uint256 bondSize,
        IBondingContract bondingContract
    ) public returns (address[] memory) {
        require(operatorsInPool() >= groupSize, "Not enough operators in pool");

        address[] memory selected = new address[](groupSize);
        uint256 nSelected = 0;

        RNG.IndexWeight[] memory selectedLeaves = new RNG.IndexWeight[](
            groupSize
        );
        uint256 selectedTotalWeight = 0;

        // XXX: These two variables do way too varied things,
        // but I need all variable slots I can free.
        // Arbitrary names to underline the absurdity.
        /* uint foo; */
        /* uint bar; */

        bytes32 rngState = seed;

        uint256 poolWeight = root.sumWeight();

        /* loop */
        while (nSelected < groupSize) {
            require(
                poolWeight > selectedTotalWeight,
                "Not enough operators in pool"
            );

            // INLINE RNG.getUniqueIndex()

            uint256 bar;
            (bar, rngState) = RNG.getIndex(
                poolWeight - selectedTotalWeight,
                rngState
            );
            // BAR is now the TRUNCATED INDEX
            for (uint256 i = 0; i < nSelected; i++) {
                if (bar >= selectedLeaves[i].index) {
                    bar += selectedLeaves[i].weight;
                    // BAR is now the UNIQUE INDEX
                }
            }

            uint256 foo;
            // BAR starts as the UNIQUE INDEX here
            (foo, bar) = pickWeightedLeafWithIndex(bar);
            // FOO is now the POSITION OF THE LEAF
            // BAR is now the STARTING INDEX of the leaf

            // FOO starts as the POSITION OF THE LEAF here
            foo = leaves[foo];
            // FOO is now the LEAF itself
            address op = foo.operator();
            foo = foo.weight();
            // FOO is now the WEIGHT OF THE OPERATOR

            // Good operators go into the group and the list to skip,
            // naughty operators get deleted
            // FOO is the WEIGHT OF THE OPERATOR here
            if (bondingContract.isEligible(op, foo, bondSize)) {
                // We insert the new index and weight into the lists,
                // keeping them both ordered by the starting indices.
                // To do this, we start by holding the new element outside the list.

                // BAR is the STARTING INDEX of the leaf
                // FOO is the WEIGHT of the operator
                RNG.IndexWeight memory tempIW = RNG.IndexWeight(bar, foo);

                for (uint256 i = 0; i < nSelected; i++) {
                    RNG.IndexWeight memory thisIW = selectedLeaves[i];
                    // With each element of the list,
                    // we check if the outside element should go before it.
                    // If true, we swap that element and the outside element.
                    if (tempIW.index < thisIW.index) {
                        selectedLeaves[i] = tempIW;
                        tempIW = thisIW;
                    }
                }

                // Now the outside element is the last one,
                // so we push it to the end of the list.
                selectedLeaves[nSelected] = tempIW;

                // And increase the skipped weight,
                // by FOO which is the WEIGHT of the operator
                selectedTotalWeight += foo;

                selected[nSelected] = op;
                nSelected += 1;
            } else {
                removeOperator(op);
                // subtract FOO which is the WEIGHT of the operator
                // from the pool weight
                poolWeight -= foo;

                // INLINE RNG.remapIndices()
                // BAR is the STARTING INDEX of the removed leaf
                // FOO is the WEIGHT of the removed operator
                for (uint256 i = 0; i < nSelected; i++) {
                    if (selectedLeaves[i].index > bar) {
                        selectedLeaves[i].index -= foo;
                    }
                }
            }
        }
        /* pool */

        // If nothing has exploded by now,
        // we should have the correct size of group.

        return selected;
    }
}
