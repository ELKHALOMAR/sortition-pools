pragma solidity ^0.5.10;

import "./GasStation.sol";
import "./RNG.sol";
import "./SortitionTree.sol";
import "./DynamicArray.sol";
import "./api/IStaking.sol";

/// @title Abstract Sortition Pool
/// @notice Abstract contract encapsulating common logic of all sortition pools.
/// @dev Inheriting implementations are expected to implement getEligibleWeight
/// function.
contract AbstractSortitionPool is SortitionTree, GasStation {
    using Leaf for uint256;
    using Position for uint256;
    using DynamicArray for DynamicArray.UintArray;
    using DynamicArray for DynamicArray.AddressArray;
    using RNG for RNG.State;

    enum Decision { Select, Skip, Delete }

    struct StakingParams {
        IStaking _contract;
        uint256 _minimum;
    }

    struct PoolParams {
        // The contract (e.g. Keep factory) this specific pool serves.
        // Only the pool owner can request groups.
        address _owner;
        // Require 10 blocks after joining before the operator can be selected for
        // a group. This reduces the degrees of freedom miners and other
        // front-runners have in conducting pool-bumping attacks.
        //
        // We don't use the stack of empty leaves until we run out of space on the
        // rightmost leaf (i.e. after 2 million operators have joined the pool).
        // It means all insertions are at the right end, so one can't reorder
        // operators already in the pool until the pool has been filled once.
        // Because the index is calculated by taking the minimum number of required
        // random bits, and seeing if it falls in the range of the total pool weight,
        // the only scenarios where insertions on the right matter are if it crosses
        // a power of two threshold for the total weight and unlocks another random
        // bit, or if a random number that would otherwise be discarded happens to
        // fall within that space.
        uint256 _initBlocks;
    }

    // Require 10 blocks after joining
    // before the operator can be selected for a group.
    uint256 constant INIT_BLOCKS = 10;

    uint256 constant GAS_DEPOSIT_SIZE = 1;

    StakingParams staking;
    PoolParams poolParams;

    /// @notice The number of blocks that must be mined before the operator who
    // joined the pool is eligible for work selection.
    function operatorInitBlocks() public pure returns (uint256) {
        return INIT_BLOCKS;
    }

    // Return whether the operator is eligible for the pool.
    function isOperatorEligible(address operator) public view returns (bool) {
        return getEligibleWeight(operator) > 0;
    }

    // Return whether the operator is present in the pool.
    function isOperatorInPool(address operator) public view returns (bool) {
        return getFlaggedOperatorLeaf(operator) != 0;
    }

    // Return whether the operator's weight in the pool
    // matches their eligible weight.
    function isOperatorUpToDate(address operator) public view returns (bool) {
        return getEligibleWeight(operator) == getPoolWeight(operator);
    }

    // Return the weight of the operator in the pool,
    // which may or may not be out of date.
    function getPoolWeight(address operator) public view returns (uint256) {
        uint256 flaggedLeaf = getFlaggedOperatorLeaf(operator);
        if (flaggedLeaf == 0) {
            return 0;
        } else {
            uint256 leafPosition = flaggedLeaf.unsetFlag();
            uint256 leafWeight = leaves[leafPosition].weight();
            return leafWeight;
        }
    }

    // Add an operator to the pool,
    // reverting if the operator is already present.
    function joinPool(address operator) public {
        uint256 eligibleWeight = getEligibleWeight(operator);
        require(
            eligibleWeight > 0,
            "Operator not eligible"
        );

        depositGas(operator);
        insertOperator(operator, eligibleWeight);
    }

    // Update the operator's weight if present and eligible,
    // or remove from the pool if present and ineligible.
    function updateOperatorStatus(address operator) public {
        uint256 eligibleWeight = getEligibleWeight(operator);
        uint256 inPoolWeight = getPoolWeight(operator);

        require(
            eligibleWeight != inPoolWeight,
            "Operator already up to date"
        );

        if (eligibleWeight == 0) {
            removeOperator(operator);
            releaseGas(operator);
        } else {
            updateOperator(operator, eligibleWeight);
        }
    }

    function generalizedSelectGroup(
        uint256 groupSize,
        bytes32 seed,
        uint256 paramsPtr,
        bool noDuplicates
    ) internal returns (address[] memory) {
        uint256 _root = root;
        bool rootChanged = false;

        DynamicArray.AddressArray memory selected;
        selected = DynamicArray.addressArray(groupSize);

        RNG.State memory rng;
        rng = RNG.initialize(
            seed,
            _root.sumWeight(),
            groupSize
        );

        while (selected.array.length < groupSize) {
            rng.generateNewIndex();

            (uint256 leafPosition, uint256 startingIndex) =
                pickWeightedLeafWithIndex(rng.currentMappedIndex, _root);

            uint256 leaf = leaves[leafPosition];
            address operator = leaf.operator();
            uint256 leafWeight = leaf.weight();

            Decision decision = decideFate(
                leaf,
                selected,
                paramsPtr
            );

            if (decision == Decision.Select) {
                selected.push(operator);
                if (noDuplicates) {
                    rng.addSkippedInterval(startingIndex, leafWeight);
                }
                rng.reseed(seed, selected.array.length);
                continue;
            }
            if (decision == Decision.Skip) {
                rng.addSkippedInterval(startingIndex, leafWeight);
                continue;
            }
            if (decision == Decision.Delete) {
                // Update the RNG
                rng.removeInterval(startingIndex, leafWeight);
                // Remove the leaf and update root
                _root = removeLeaf(leafPosition, _root);
                rootChanged = true;
                // Remove the record of the operator's leaf and release gas
                removeOperatorLeaf(operator);
                releaseGas(operator);
                continue;
            }
        }
        if (rootChanged) {
            root = _root;
        }
        return selected.array;
    }

    // Return the eligible weight of the operator,
    // which may differ from the weight in the pool.
    // Return 0 if ineligible.
    function getEligibleWeight(address operator) internal view returns (uint256);

    function decideFate(
        uint256 leaf,
        DynamicArray.AddressArray memory selected,
        uint256 paramsPtr) internal view returns (Decision);

    function gasDepositSize() internal pure returns (uint256) {
        return GAS_DEPOSIT_SIZE;
    }
}
