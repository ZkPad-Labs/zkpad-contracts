from datetime import datetime

import pytest
import pytest_asyncio

from signers import MockSigner
from tests.types import Data
from utils import *
import asyncio
from generate_proof_balance import generate_proof, pack_intarray

from starkware.starknet.testing.starknet import Starknet
from starkware.cairo.common.cairo_secp.secp_utils import split
from starkware.starknet.public.abi import get_selector_from_name

account_path = 'openzeppelin/account/presets/Account.cairo'
sbt_contract_factory_path = 'SBTs/AstralyBalanceSBTContractFactory.cairo'
balance_proof_badge_path = 'SBTs/AstralyBalanceProofBadge.cairo'

prover = MockSigner(1234321)


@pytest.fixture(scope='module')
def event_loop():
    return asyncio.new_event_loop()


@pytest_asyncio.fixture(scope='module')
async def get_starknet():
    starknet = await Starknet.empty()
    set_block_timestamp(starknet.state, int(
        datetime.today().timestamp()))  # time.time()
    set_block_number(starknet.state, 1)
    return starknet


@pytest.fixture(scope='module')
def contract_defs():
    account_def = get_contract_def(account_path)
    sbt_contract_factory_def = get_contract_def(
        sbt_contract_factory_path, disable_hint_validation=True)
    balance_proof_badge_def = get_contract_def(
        balance_proof_badge_path, disable_hint_validation=True)
    return account_def, sbt_contract_factory_def, balance_proof_badge_def


@pytest_asyncio.fixture(scope='module')
async def contacts_init(contract_defs, get_starknet):
    starknet = get_starknet
    account_def, sbt_contract_factory_def, balance_proof_badge_def = contract_defs
    await starknet.declare(contract_class=account_def)
    prover_account = await starknet.deploy(
        contract_class=account_def,
        constructor_calldata=[prover.public_key],
        disable_hint_validation=True,
        contract_address_salt=prover.public_key
    )

    await starknet.declare(contract_class=sbt_contract_factory_def)
    sbt_contract_factory = await starknet.deploy(
        contract_class=sbt_contract_factory_def,
        constructor_calldata=[],
        disable_hint_validation=True
    )

    balance_proof_class_hash = await starknet.declare(contract_class=balance_proof_badge_def)

    await prover.send_transaction(prover_account, sbt_contract_factory.contract_address, "initializer",
                                  [balance_proof_class_hash.class_hash, prover_account.contract_address])

    return prover_account, sbt_contract_factory


@pytest.fixture
def contracts_factory(contract_defs, contacts_init, get_starknet):
    account_def, sbt_contract_factory_def, _ = contract_defs
    prover_account, sbt_contract_factory = contacts_init
    _state = get_starknet.state.copy()

    prover_cached = cached_contract(
        _state, account_def, prover_account)
    sbt_contract_factory_cached = cached_contract(
        _state, sbt_contract_factory_def, sbt_contract_factory)

    return prover_cached, sbt_contract_factory_cached, _state


@pytest.mark.asyncio
async def test_create_sbt_contract_function(contracts_factory, contract_defs):
    prover_account, sbt_contract_factory, starknet_state = contracts_factory
    _, _, balance_proof_badge_def = contract_defs
    erc20_token = "0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72"
    block_number = 7415645
    min_balance = 1
    create_sbt_transaction_receipt = await prover.send_transaction(prover_account,
                                                                   sbt_contract_factory.contract_address,
                                                                   "createSBTContract",
                                                                   [block_number, min_balance, int(erc20_token, 16)])

    balance_proof_badge_contract = StarknetContract(starknet_state, balance_proof_badge_def.abi,
                                                    create_sbt_transaction_receipt.result.response[0], None)

    assert min_balance == (await balance_proof_badge_contract.minBalance().call()).result.min
    assert int(erc20_token, 16) == (await balance_proof_badge_contract.tokenAddress().call()).result.address


@pytest.mark.asyncio
async def test_proof(contracts_factory, contract_defs):
    prover_account, sbt_contract_factory, starknet_state = contracts_factory
    _, _, balance_proof_badge_def = contract_defs

    LINK_token_address = "0x326C977E6efc84E512bB9C30f76E30c160eD06FB"
    block_number = 7486880
    min_balance = 1
    create_sbt_transaction_receipt = await prover.send_transaction(prover_account,
                                                                   sbt_contract_factory.contract_address,
                                                                   "createSBTContract",
                                                                   [block_number, min_balance,
                                                                    int(LINK_token_address, 16)])

    balance_proof_badge_contract = StarknetContract(starknet_state, balance_proof_badge_def.abi,
                                                    create_sbt_transaction_receipt.result.response[0], None)

    ethereum_address = "0x4Db4bB41758F10D97beC54155Fdb59b879207F92"
    ethereum_pk = "eb5a6c2a9e46618a92b40f384dd9e076480f1b171eb21726aae34dc8f22fe83f"
    rpc_node = "https://eth-goerli.g.alchemy.com/v2/uXpxHR8fJBH3fjLJpulhY__jXbTGNjN7"
    storage_slot = hex(1)
    proof = generate_proof(ethereum_address, ethereum_pk, hex(prover_account.contract_address), rpc_node, storage_slot,
                           LINK_token_address, block_number)

    args = list()
    args.append(prover_account.contract_address)
    args.append(starknet_state.general_config.chain_id.value)
    args.append(len(proof['accountProof']))
    args.append(len(proof['storageProof'][0]['proof']))

    state_root = pack_intarray(proof['stateRoot'])
    args.append(len(state_root))  # state_root__len
    args += state_root

    storage_slot_ = pack_intarray(proof['storageSlot'])
    args.append(len(storage_slot_))  # storage_slot__len
    args += storage_slot_

    storage_hash_ = pack_intarray(proof['storageHash'])
    args.append(len(storage_hash_))  # storage_hash__len
    args += storage_hash_

    message_ = pack_intarray(proof['signature']['message'])
    args.append(len(message_))  # message__len
    args += message_
    args.append(len(proof['signature']['message'][2:]) // 2)

    R_x_ = split(proof['signature']['R_x'])
    args.append(len(R_x_))  # R_x__len
    args += R_x_

    R_y_ = split(proof['signature']['R_y'])
    args.append(len(R_y_))  # R_y__len
    args += R_y_

    s_ = split(proof['signature']['s'])
    args.append(len(s_))  # s__len
    args += s_

    args.append(proof['signature']['v'])

    storage_key_ = pack_intarray(proof['storageProof'][0]['key'])
    args.append(len(storage_key_))  # storage_key__len
    args += storage_key_

    storage_value_ = pack_intarray(hex(proof['storage_value']))
    args.append(len(storage_value_))  # storage_value__len
    args += storage_value_

    storage_proof = list(map(lambda element: Data.from_hex(
        element).to_ints(), proof['storageProof'][0]['proof']))
    flat_storage_proof = []
    flat_storage_proof_sizes_bytes = []
    flat_storage_proof_sizes_words = []
    for proof_element in storage_proof:
        flat_storage_proof += proof_element.values
        flat_storage_proof_sizes_bytes += [proof_element.length]
        flat_storage_proof_sizes_words += [len(proof_element.values)]

    args.append(len(flat_storage_proof))
    args += flat_storage_proof

    args.append(len(flat_storage_proof_sizes_words))
    args += flat_storage_proof_sizes_words

    args.append(len(flat_storage_proof_sizes_bytes))
    args += flat_storage_proof_sizes_bytes

    receipt = await prover.send_transaction(prover_account, balance_proof_badge_contract.contract_address, "mint",
                                            [*args])

    event_signature = get_selector_from_name("BadgeMinted")
    assert next(
        (x for x in receipt.raw_events if event_signature in x.keys), None) is not None
