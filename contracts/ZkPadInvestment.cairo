%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.math import assert_not_zero, assert_le
from starkware.cairo.common.uint256 import Uint256, uint256_check, uint256_lt
from starkware.cairo.common.registers import get_label_location
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.pow import pow
from starkware.cairo.common.bool import TRUE, FALSE
from starkware.starknet.common.syscalls import get_caller_address, get_block_timestamp

from openzeppelin.token.erc20.interfaces.IERC20 import IERC20
from openzeppelin.security.safemath import uint256_checked_add, uint256_checked_sub_le, uint256_checked_sub_lt, uint256_checked_div_rem

from contracts.utils import get_array
from contracts.erc4626.ERC4626 import asset

@contract_interface
namespace Strategy:
   func redeemUnderlying(amount : felt) -> (res : Uint256):
   end
   func balanceOfUnderlying(user : felt) -> (res : Uint256):
   end
   func underlying() -> (address : felt):
   end
   func mint(amount : Uint256) -> (res : Uint256):
   end
end

# # @notice Data for a given strategy.
# # @param trusted Whether the strategy is trusted.
# # @param balance The amount of underlying tokens held in the strategy.
struct StrategyData:
    member trusted : felt  # 0 (false) or 1 (true)
    member balance : felt
end

####################################################################################
#                                   Events
####################################################################################
@event
func FeePercentUpdated(user : felt, newFeePercent : felt):
end

@event
func HarvestWindowUpdated(user : felt, newHarvestWindow : felt):
end

# @notice Emitted when the harvest delay is updated.
# @param user The authorized user who triggered the update.
# @param newHarvestDelay The new harvest delay.
@event
func HarvestDelayUpdated(user : felt, newHarvestDelay : felt):
end

# @notice Emitted when the harvest delay is scheduled to be updated next harvest.
# @param user The authorized user who triggered the update.
# @param newHarvestDelay The scheduled updated harvest delay.
@event
func HarvestDelayUpdateScheduled(user : felt, newHarvestDelay : felt):
end

# @notice Emitted when the target float percentage is updated.
# @param user The authorized user who triggered the update.
# @param newTargetFloatPercent The new target float percentage.
@event
func TargetFloatPercentUpdated(user : felt, newTargetFloatPercent : Uint256):
end

@event
func Harvest(user : felt, strategies_len : felt, strategies : felt*):
end

####################################################################################
#                               Storage Variables
####################################################################################

@storage_var
func base_unit() -> (unit : felt):
end

@storage_var
func fee_percent() -> (fee : felt):
end

@storage_var
func harvest_window() -> (window : felt):
end

@storage_var
func harvest_delay() -> (delay : felt):
end

@storage_var
func next_harvest_delay() -> (delay : felt):
end

# # @notice The desired float percentage of holdings.
# # @dev A fixed point number where 1e18 represents 100% and 0 represents 0%.
@storage_var
func target_float_percent() -> (percent : Uint256):
end

# # @notice The total amount of underlying tokens held in strategies at the time of the last harvest.
# # @dev Includes maxLockedProfit, must be correctly subtracted to compute available/free holdings.
@storage_var
func total_strategy_holdings() -> (holdings : Uint256):
end

# # @notice Maps strategies to data the Vault holds on them.
@storage_var
func strategy_data(strategy : felt) -> (data : StrategyData):
end

# # @notice A timestamp representing when the first harvest in the most recent harvest window occurred.
# # @dev May be equal to lastHarvest if there was/has only been one harvest in the most last/current window.
@storage_var
func last_harvest_window_start() -> (start : felt):
end

# # @notice A timestamp representing when the most recent harvest occurred.
@storage_var
func last_harvest() -> (harvest : felt):
end

# # @notice The amount of locked profit at the end of the last harvest.
@storage_var
func max_locked_profit() -> (profit : felt):
end

# # @notice An ordered array of strategies representing the withdrawal queue.
# # @dev The queue is processed in descending order.
# # @dev Returns a tupled-array of (array_len, Strategy[])
@storage_var
func withdrawal_queue(index : felt) -> (strategy_address : felt):
end

@storage_var
func withdrawal_queue_length() -> (length : felt):
end

namespace ZkPadInvestment:
    ####################################################################################
    #                                  View Functions
    ####################################################################################
    # # @notice Gets the full withdrawal queue.
    # # @return An ordered array of strategies representing the withdrawal queue.
    @view
    func getWithdrawalQueue{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        ) -> (queue_len : felt, queue : felt*):
        alloc_locals
        let (length : felt) = withdrawal_queue_length.read()
        let (mapping_ref : felt) = get_label_location(withdrawal_queue.read)
        let (array : felt*) = alloc()

        get_array(length, array, mapping_ref)
        return (length, array)
    end

    @view
    func totalFloat{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        float : Uint256
    ):
        let (current_float_percent : Uint256) = target_float_percent.read()
        return (current_float_percent)
    end

    # @notice Calculates the current amount of locked profit.
    # @return The current amount of locked profit.
    @view
    func lockedProfit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        res : felt
    ):
        alloc_locals
        let (previous_harvest : felt) = last_harvest.read()
        let (harvest_interval : felt) = harvest_delay.read()
        let (block_timestamp : felt) = get_block_timestamp()

        let (harvest_delay_passed : felt) = is_le(
            previous_harvest + harvest_interval, block_timestamp
        )
        # If the harvest delay has passed, there is no locked profit.
        # Cannot overflow on human timescales since harvestInterval is capped.
        if harvest_delay_passed == TRUE:
            return (0)
        end

        let (maximum_locked_profit : felt) = max_locked_profit.read()

        # Compute how much profit remains locked based on the last harvest and harvest delay.
        # It's impossible for the previous harvest to be in the future, so this will never underflow.
        # maximumLockedProfit - (maximumLockedProfit * (block.timestamp - previousHarvest)) / harvestInterval;
        let sub = block_timestamp - previous_harvest
        let mul = maximum_locked_profit * sub
        let div = mul / harvest_interval
        return (maximum_locked_profit - div)
    end

    # @notice Calculates the total amount of underlying tokens the Vault holds.
    # @return totalUnderlyingHeld The total amount of underlying tokens the Vault holds.
    @view
    func totalHoldings{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        total_underlying_held : Uint256
    ):
        let (locked_profit : felt) = lockedProfit()
        let (current_total_strategy_holdings : Uint256) = total_strategy_holdings.read()
        let (total_underlying_held : Uint256) = uint256_checked_sub_le(
            current_total_strategy_holdings, Uint256(locked_profit, 0)
        )
        let (total_float : Uint256) = totalFloat()
        let (add_float : Uint256) = uint256_checked_add(total_underlying_held, total_float)
        return (add_float)
    end

    ####################################################################################
    #                                  External Functions
    ####################################################################################
    func set_fee_percent{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        fee : felt
    ):
        assert_not_zero(fee)
        fee_percent.write(fee)
        let (caller : felt) = get_caller_address()
        FeePercentUpdated.emit(caller, fee)
        return ()
    end

    # # @notice Sets a new harvest window.
    # # @param newHarvestWindow The new harvest window.
    # # @dev harvest_delay must be set before calling.
    func set_harvest_window{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        window : felt
    ):
        let (delay) = harvest_delay.read()
        assert_le(window, delay)
        harvest_window.write(window)
        let (caller : felt) = get_caller_address()
        HarvestDelayUpdated.emit(caller, window)
        return ()
    end

    # # @notice Sets a new harvest delay.
    # # @param newHarvestDelay The new harvest delay.
    func set_harvest_delay{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        new_delay : felt
    ):
        alloc_locals

        let (local delay) = harvest_delay.read()
        assert_not_zero(new_delay)
        assert_le(new_delay, 31536000)  # 31,536,000 = 365 days = 1 year

        let (caller : felt) = get_caller_address()
        # If the previous delay is 0, we should set immediately
        if delay == 0:
            harvest_delay.write(new_delay)
            HarvestDelayUpdated.emit(caller, new_delay)
        else:
            next_harvest_delay.write(new_delay)
            HarvestDelayUpdateScheduled.emit(caller, new_delay)
        end
        return ()
    end

    # # @notice Sets a new target float percentage.
    func set_target_float_percent{
        syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
    }(new_float : Uint256):
        alloc_locals

        uint256_check(new_float)
        let (local lt : felt) = uint256_lt(new_float, Uint256(2 ** 128 - 1, 2 ** 128 - 1))
        assert lt = 1
        target_float_percent.write(new_float)
        let (caller : felt) = get_caller_address()
        TargetFloatPercentUpdated.emit(caller, new_float)
        return ()
    end

    # @notice Harvest a set of trusted strategies.
    # @param strategies The trusted strategies to harvest.
    # @dev Will always revert if called outside of an active
    # harvest window or before the harvest delay has passed.
    func harvest_investment{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        strategies_len : felt, strategies : felt*
    ):
        alloc_locals
        let (previous_harvest : felt) = last_harvest.read()
        let (harvest_interval : felt) = harvest_delay.read()
        let (block_timestamp : felt) = get_block_timestamp()

        let (harvest_delay_passed : felt) = is_le(
            previous_harvest + harvest_interval, block_timestamp
        )
        # If this is the first harvest after the last window:
        if harvest_delay_passed == TRUE:
            last_harvest_window_start.write(block_timestamp)
            tempvar syscall_ptr : felt* = syscall_ptr
            tempvar range_check_ptr = range_check_ptr
            tempvar pedersen_ptr : HashBuiltin* = pedersen_ptr
        else:
            let (current_last_harvest_window_start_value : felt) = last_harvest_window_start.read()
            let (current_harvest_window : felt) = harvest_window.read()
            with_attr error_message("BAD_HARVEST_TIME"):
                # We know this harvest is not the first in the window so we need to ensure it's within it.
                assert_le(
                    block_timestamp,
                    current_last_harvest_window_start_value + current_harvest_window,
                )
            end
            tempvar syscall_ptr : felt* = syscall_ptr
            tempvar range_check_ptr = range_check_ptr
            tempvar pedersen_ptr : HashBuiltin* = pedersen_ptr
        end

        let (old_total_strategy_holdings : Uint256) = total_strategy_holdings.read()
        let (total_profit_accrued : Uin256,
            new_total_strategy_holdings : Uint256) = _check_strategies(
            strategies_len, strategies, 0, 0, old_total_strategy_holdings
        )
        let (fee_percent : felt) = fee_percent.read()
        let (fees_accrued : Uin256) = uint256_checked_div_rem(total_profit_accrued, Uint256(fee_percent * (1 ** 18), 0))


        ### TODO: MINT xZKP

        let (current_locked_profit :felt) = lockedProfit()
        max_locked_profit.write(current_locked_profit + total_profit_accrued - fees_accrued)

        total_strategy_holdings.write(new_total_strategy_holdings)
        last_harvest.write(block_timestamp)


        let (new_harvest_delay : felt) = next_harvest_delay.read()
        if new_harvest_delay != 0:
            harvest_delay.write(new_harvest_delay)
            next_harvest_delay.write(0)
            HarvestDelayUpdated.emit(caller, new_harvest_delay)
        end


        let (caller : felt) = get_caller_address()
        Harvest.emit(caller, strategies_len, strategies)
        return ()
    end

    func _check_strategies{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        strategies_len : felt,
        strategies : felt*,
        index,
        total_profit_accrued : Uint256,
        new_total_strategy_holdings : Uint256,
    ) -> (new_total_strategy_holdings : Uint256):
        alloc_locals
        if index == strategies_len:
            return (total_profit_accrued, new_total_strategy_holdings)
        end
        let (current_strategy_data : StrategyData) = strategy_data.read(strategies[index])
        with_attr error_message("UNTRUSTED_STRATEGY"):
            assert current_strategy_data.trusted = TRUE
        end
        let (underlying_asset : felt) = asset()
        let (balance_last_harvest : Uint256) = current_strategy_data.balance
        let (balance_this_harvest : Uint256) = IERC20.balanceOf(
            underlying_asset, strategies[index]
        )

        strategy_data.write(strategies[index], TRUE, balance_this_harvest)

        local new_total_profit_accrued : Uint256

        let (is_last_harvest_balance_lt : felt) = uint256_lt(balance_last_harvest, balance_this_harvest)
        if is_last_harvest_balance_lt == TRUE:
            let (profit : Uin256) = uint256_checked_sub_lt(balance_this_harvest, balance_last_harvest)
            new_total_profit_accrued = uint256_checked_add(total_profit_accrued, profit)
        else:
            new_total_profit_accrued = total_profit_accrued
        end

        return _check_strategies(
            strategies_len,
            strategies,
            index + 1,
            new_total_profit_accrued,
            new_total_strategy_holdings + balance_this_harvest - balance_last_harvest,
        )
    end
end
