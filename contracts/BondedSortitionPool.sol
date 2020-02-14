pragma solidity ^0.5.10;

import "./AbstractSortitionPool.sol";
import "./RNG.sol";
import "./api/IStaking.sol";
import "./api/IBonding.sol";

/// @title Bonded Sortition Pool
/// @notice A logarithmic data structure used to store the pool of eligible
/// operators weighted by their stakes. It allows to select a group of operators
/// based on the provided pseudo-random seed and bonding requirements.
/// @dev Keeping pool up to date cannot be done eagerly as proliferation of
/// privileged customers could be used to perform DOS attacks by increasing the
/// cost of such updates. When a sortition pool prospectively selects an
/// operator, the selected operator’s eligibility status and weight needs to be
/// checked and, if necessary, updated in the sortition pool. If the changes
/// would be detrimental to the operator, the operator selection is performed
/// again with the updated input to ensure correctness.
contract BondedSortitionPool is AbstractSortitionPool {
    // The pool should specify a reasonable minimum bond
    // for operators trying to join the pool,
    // to prevent griefing by operators joining without enough bondable value.
    // After we start selecting groups
    // this value can be set to equal the most recent request's bondValue.
    struct BondingParams {
        IBonding _contract;
        uint256 _minimumBondableValue;
    }

    struct PoolParams {
        StakingParams _staking;
        BondingParams _bonding;
        address _poolOwner;
        uint256 _root;
        uint256 _poolWeight;
        bool _rootChanged;
        uint256 _selectedTotalWeight;
        uint256 _selectedCount;
        bytes32 _rngState;
    }

    // Require 10 blocks after joining
    // before the operator can be selected for a group.
    uint256 constant INIT_BLOCKS = 10;

    BondingParams bonding;

    constructor(
        IStaking _stakingContract,
        IBonding _bondingContract,
        uint256 _minimumStake,
        uint256 _minimumBondableValue,
        address _poolOwner
    ) public {
        require(_minimumStake > 0, "Minimum stake cannot be zero");

        staking = StakingParams(_stakingContract, _minimumStake);
        bonding = BondingParams(_bondingContract, _minimumBondableValue);
        poolOwner = _poolOwner;
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
    /// @param bondValue Size of the requested bond per operator
    function selectSetGroup(
        uint256 groupSize,
        bytes32 seed,
        uint256 bondValue
    ) public returns (address[] memory) {
        uint256 leafPosition = root;
        PoolParams memory params = PoolParams(
            staking,
            bonding,
            poolOwner,
            leafPosition,
            leafPosition.sumWeight(),
            false,
            0,
            0,
            seed
        );

        if (params._bonding._minimumBondableValue != bondValue) {
            params._bonding._minimumBondableValue = bondValue;
            bonding._minimumBondableValue = bondValue;
        }

        address[] memory selected = new address[](groupSize);

        uint256[] memory selectedLeaves = new uint256[](
            groupSize
        );

        // selectedTotalWeight = 0;
        // uint256 selectedCount = 0;

        // uint256 leafPosition;
        leafPosition = 0;
        uint256 uniqueIndex;

        /* loop */
        while (params._selectedCount < groupSize) {
            require(
                params._poolWeight > params._selectedTotalWeight,
                "Not enough operators in pool"
            );

            (uniqueIndex, params._rngState) = RNG.getUniqueIndex(
                params._poolWeight,
                params._rngState,
                selectedLeaves,
                params._selectedTotalWeight
            );

            uint256 startingIndex;
            (leafPosition, startingIndex) = pickWeightedLeafWithIndex(uniqueIndex, params._root);

            uint256 theLeaf = leaves[leafPosition];
            // Check that the leaf is old enough
            // FIXME: inefficient, can lead to an infinite loop.
            if (theLeaf.creationBlock() + INIT_BLOCKS >= block.number) {
                continue;
            }
            address operator = theLeaf.operator();
            uint256 leafWeight = theLeaf.weight();

            // Good operators go into the group and the list to skip,
            // naughty operators get deleted
            if (queryEligibleWeight(operator, params) >= leafWeight) {
                // We insert the new index and weight into the lists,
                // keeping them both ordered by the starting indices.
                // To do this, we start by holding the new element outside the list.

                uint256 lastOperator = Operator.insert(
                    selectedLeaves,
                    Leaf.make(operator, startingIndex, leafWeight)
                );

                // RNG.IndexWeight memory tempIW = RNG.IndexWeight(
                //     startingIndex,
                //     leafWeight
                // );

                // for (uint256 i = 0; i < params._selectedCount; i++) {
                //     RNG.IndexWeight memory thisIW = selectedLeaves[i];
                //     // With each element of the list,
                //     // we check if the outside element should go before it.
                //     // If true, we swap that element and the outside element.
                //     if (tempIW.index < thisIW.index) {
                //         selectedLeaves[i] = tempIW;
                //         tempIW = thisIW;
                //     }
                // }

                // Now the outside element is the last one,
                // so we push it to the end of the list.
                selectedLeaves[params._selectedCount] = lastOperator;

                // And increase the skipped weight,
                params._selectedTotalWeight += leafWeight;

                selected[params._selectedCount] = operator;
                params._selectedCount += 1;
            } else {
                params._root = removeLeaf(leafPosition, params._root);
                removeOperatorLeaf(operator);
                releaseGas(operator);
                // subtract the weight of the operator from the pool weight
                params._poolWeight -= leafWeight;
                params._rootChanged = true;

                // selectedLeaves = RNG.remapIndices(
                RNG.remapIndices(
                    startingIndex,
                    leafWeight,
                    selectedLeaves
                );
            }
        }
        /* pool */

        if (params._rootChanged) {
            root = params._root;
        }

        // If nothing has exploded by now,
        // we should have the correct size of group.

        return selected;
    }

    // Return the eligible weight of the operator,
    // which may differ from the weight in the pool.
    // Return 0 if ineligible.
    function getEligibleWeight(address operator) internal view returns (uint256) {
        PoolParams memory params = PoolParams(
            staking,
            bonding,
            poolOwner,
            0,
            0, // the pool weight doesn't matter here
            false,
            0,
            0,
            bytes32(0)
        );
        return queryEligibleWeight(operator, params);
    }

    function queryEligibleWeight(
        address operator,
        PoolParams memory params
    ) internal view returns (uint256) {
        address ownerAddress = params._poolOwner;

        // Get the amount of bondable value available for this pool.
        // We only care that this covers one single bond
        // regardless of the weight of the operator in the pool.
        uint256 bondableValue = params._bonding._contract.availableUnbondedValue(
            operator,
            ownerAddress,
            address(this)
        );

        // Don't query stake if bond is insufficient.
        if (bondableValue < params._bonding._minimumBondableValue) {
            return 0;
        }

        uint256 eligibleStake = params._staking._contract.eligibleStake(
            operator,
            ownerAddress
        );

        // Weight = floor(eligibleStake / mimimumStake)
        // Ethereum uint256 division performs implicit floor
        // If eligibleStake < minimumStake, return 0 = ineligible.
        return (eligibleStake / params._staking._minimum);
    }

    function allocatePush(uint256[] memory array, uint256 item) internal {
        uint256 freeMemoryPointer;
        uint256 arrayLastItemPointer;
        uint256 arrayLength = array.length;
        // solium-disable-next-line security/no-inline-assembly
        assembly {
            freeMemoryPointer := mload(0x40)
            arrayLastItemPointer := add(array, mul(add(arrayLength, 1), 0x20))
        }
        require(
            freeMemoryPointer == (arrayLastItemPointer + 0x20),
            "Memory has been allocated past dynamic array"
        );
        // solium-disable-next-line security/no-inline-assembly
        assembly {
            mstore(freeMemoryPointer, item)
            mstore(array, add(arrayLength, 1))
            mstore(0x40, add(freeMemoryPointer, 0x20))
        }
    }
}
