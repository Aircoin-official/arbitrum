// SPDX-License-Identifier: Apache-2.0

/*
 * Copyright 2020, Offchain Labs, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

pragma solidity ^0.6.11;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Create2.sol";

import "arb-bridge-eth/contracts/bridge/interfaces/IInbox.sol";
import "arb-bridge-eth/contracts/bridge/interfaces/IOutbox.sol";

import "../../libraries/ITokenGateway.sol";
import "../../libraries/TokenGateway.sol";
import "../../libraries/ClonableBeaconProxy.sol";

abstract contract L1ArbitrumGateway is TokenGateway {
    using SafeERC20 for IERC20;

    address public inbox;

    function isCounterpartGateway() internal view virtual override returns (bool) {
        IOutbox outbox = IOutbox(IInbox(inbox).bridge().activeOutbox());
        return counterpartGateway == outbox.l2ToL1Sender();
    }

    function _initialize(
        address _l2Counterpart,
        address _router,
        address _inbox
    ) internal virtual {
        // L1 gateway must have a router
        require(_router != address(0), "BAD_ROUTER");
        TokenGateway._initialize(_l2Counterpart, _router);
        require(_inbox != address(0), "BAD_INBOX");
        router = _router;
        inbox = _inbox;
    }

    /**
     * @notice Finalizes a withdrawal via Outbox message; callable only by L2Gateway.outboundTransfer
     * @param _token L1 address of token being withdrawn from
     * @param _from initiator of withdrawal
     * @param _to address the L2 withdrawal call set as the destination.
     * @param _amount Token amount being withdrawn
     * @param _data encoded exitNum (Sequentially increasing exit counter determined by the L2Gateway) and additinal hook data
     */
    function finalizeInboundTransfer(
        address _token,
        address _from,
        address _to,
        uint256 _amount,
        bytes calldata _data
    ) external virtual override onlyCounterpartGateway returns (bytes memory) {
        (uint256 exitNum, bytes memory extraData) = abi.decode(_data, (uint256, bytes));

        // TODO: add withdraw and call
        // TODO: add transferExit
        IERC20(_token).safeTransfer(_to, _amount);
        emit InboundTransferFinalized(_token, _from, _to, exitNum, _amount, _data);

        return bytes("");
    }

    function createOutboundTx(
        address _user,
        uint256 _maxSubmissionCost,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes memory _data
    ) internal virtual returns (uint256) {
        // msg.value is sent, but 0 is set to the L2 call value
        // the eth sent is used to pay for the tx's gas
        uint256 seqNum =
            IInbox(inbox).createRetryableTicket{ value: msg.value }(
                counterpartGateway,
                0,
                _maxSubmissionCost,
                _user,
                _user,
                _maxGas,
                _gasPriceBid,
                _data
            );
        return seqNum;
    }

    /**
     * @notice Deposit ERC20 token from Ethereum into Arbitrum. If L2 side hasn't been deployed yet, includes name/symbol/decimals data for initial L2 deploy. Initiate by GatewayRouter.
     * @param _token L1 address of ERC20
     * @param _to account to be credited with the tokens in the L2 (can be the user's L2 account or a contract)
     * @param _amount Token Amount
     * @param _maxGas Max gas deducted from user's L2 balance to cover L2 execution
     * @param _gasPriceBid Gas price for L2 execution
     * @param _data encoded data from router and user
     * @return res abi encoded inbox sequence number
     */
    //  * @param maxSubmissionCost Max gas deducted from user's L2 balance to cover base submission fee
    function outboundTransfer(
        address _token,
        address _to,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes calldata _data
    ) external payable virtual override onlyRouter returns (bytes memory res) {
        address _from;
        uint256 seqNum;
        {
            uint256 _maxSubmissionCost;
            bytes memory extraData;
            (_from, _maxSubmissionCost, extraData) = parseOutboundData(_data);

            // escrow funds in gateway
            IERC20(_token).safeTransferFrom(_from, address(this), _amount);

            bytes memory outboundCalldata =
                getOutboundCalldata(_token, _from, _to, _amount, extraData);

            seqNum = createOutboundTx(
                _from,
                _maxSubmissionCost,
                _maxGas,
                _gasPriceBid,
                outboundCalldata
            );
        }

        emit OutboundTransferInitiated(_token, _from, _to, seqNum, _amount, _data);
        return abi.encode(seqNum);
    }

    function parseOutboundData(bytes memory _data)
        internal
        view
        virtual
        returns (
            address _from,
            uint256 _maxSubmissionCost,
            bytes memory _extraData
        )
    {
        if (isRouter()) {
            // router encoded
            (_from, _extraData) = abi.decode(_data, (address, bytes));
        } else {
            _from = msg.sender;
            _extraData = _data;
        }
        // user encoded
        (_maxSubmissionCost, _extraData) = abi.decode(_extraData, (uint256, bytes));
    }

    function isRouter() internal view virtual override returns (bool) {
        return msg.sender == router;
    }

    function getOutboundCalldata(
        address _token,
        address _from,
        address _to,
        uint256 _amount,
        bytes memory _data
    ) public view virtual override returns (bytes memory outboundCalldata);
}

/**
 * @title Layer 1 contract for bridging standard ERC20s
 * @notice This contract handles token deposits, holds the escrowed tokens on layer 1, and (ultimately) finalizes withdrawals.
 * @dev Any ERC20 that requires non-standard functionality should use a separate gateway.
 * Messages to layer 2 use the inbox's createRetryableTicket method.
 */
contract L1ERC20Gateway is L1ArbitrumGateway {
    // used for create2 address calculation
    bytes32 public constant cloneableProxyHash = keccak256(type(ClonableBeaconProxy).creationCode);

    function initialize(
        address _l2Counterpart,
        address _router,
        address _inbox
    ) public virtual {
        L1ArbitrumGateway._initialize(_l2Counterpart, _router, _inbox);
    }

    /**
     * @notice utility function used to perform external read-only calls.
     * @dev the result is returned even if the call failed, the L2 is expected to
     * identify and deal with this.
     * @return result bytes, even if the call failed.
     */
    function callStatic(address targetContract, bytes4 targetFunction)
        internal
        view
        returns (bytes memory)
    {
        (bool success, bytes memory res) =
            targetContract.staticcall(abi.encodeWithSelector(targetFunction));
        return res;
    }

    function getOutboundCalldata(
        address _token,
        address _from,
        address _to,
        uint256 _amount,
        bytes memory _data
    ) public view virtual override returns (bytes memory outboundCalldata) {
        // TODO: cheaper to make static calls or save isDeployed to storage?
        bytes memory deployData =
            abi.encode(
                callStatic(_token, ERC20.name.selector),
                callStatic(_token, ERC20.symbol.selector),
                callStatic(_token, ERC20.decimals.selector)
            );

        outboundCalldata = abi.encodeWithSelector(
            ITokenGateway.finalizeInboundTransfer.selector,
            _token,
            _from,
            _to,
            _amount,
            abi.encode(deployData, _data)
        );

        return outboundCalldata;
    }

    /**
     * @notice Calculate the address used when bridging an ERC20 token
     * @dev this always returns the same as the L1 oracle, but may be out of date.
     * For example, a custom token may have been registered but not deploy or the contract self destructed.
     * @param l1ERC20 address of L1 token
     * @return L2 address of a bridged ERC20 token
     */
    function calculateL2TokenAddress(address l1ERC20)
        external
        view
        virtual
        override
        onlyRouter
        returns (address)
    {
        // will revert if not called by router
        return _calculateL2TokenAddress(l1ERC20);
    }

    function _calculateL2TokenAddress(address l1ERC20)
        internal
        view
        virtual
        override
        returns (address)
    {
        bytes32 salt = getSalt(l1ERC20);
        return Create2.computeAddress(salt, cloneableProxyHash, counterpartGateway);
    }

    function getSalt(address l1ERC20) internal pure virtual returns (bytes32) {
        return keccak256(abi.encode(l1ERC20));
    }
}