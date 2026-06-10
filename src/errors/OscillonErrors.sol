// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

error NotOwner();
error PoolNotRegistered();
error PoolAlreadyRegistered();
error UnsupportedToken(address token);
error OracleAnswerInvalid();
error OracleStale(uint256 updatedAt, uint256 blockTime);
error OracleRoundIncomplete(uint80 roundId, uint80 answeredInRound);
error ZeroAddress();
error SameStable();
error NotStablePool();
error OracleNotApproved(address oracle);
error AdapterNotApproved(address adapter);
error InvalidAdapter(address adapter);
error ExactOutputDisabledDuringDepeg(uint256 depegBps);
error SwapCapExceeded();
error TransferFailed();
error SequencerDown();
