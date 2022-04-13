import pytest
from utils import (
    Signer, to_uint, str_to_felt, MAX_UINT256, get_contract_def, cached_contract, assert_revert, assert_event_emitted
)
from starkware.starknet.definitions.error_codes import StarknetErrorCode
from starkware.starkware_utils.error_handling import StarkException
from starkware.starknet.testing.starknet import Starknet

deployer = Signer(1234)
admin1 = Signer(2345)
admin2 = Signer(3456)

@pytest.fixture(scope='module')
def contract_defs():
    account_def = get_contract_def('openzeppelin/account/Account.cairo')
    zk_pad_admin_def = get_contract_def('ZkPadAdmin.cairo')
    return account_def, zk_pad_admin_def

@pytest.fixture(scope='module')
async def contacts_init(contract_defs):
    starknet = await Starknet.empty()
    account_def, zk_pad_admin_def = contract_defs

    deployer_account = await starknet.deploy(
        contract_def=account_def,
        constructor_calldata=[deployer.public_key]
    )
    admin1_account = await starknet.deploy(
        contract_def=account_def,
        constructor_calldata=[admin1.public_key]
    )
    admin2_account = await starknet.deploy(
        contract_def=account_def,
        constructor_calldata=[admin2.public_key]
    )

    zk_pad_admin = await starknet.deploy(
        contract_def=zk_pad_admin_def,
        constructor_calldata=[
            2,
            [admin1_account.contract_address, admin2_account.contract_address]
        ],
    )

    return (
        starknet.state,
        deployer_account,
        admin1_account,
        admin2_account,
        zk_pad_admin
    )


