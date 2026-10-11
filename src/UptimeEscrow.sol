// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title UptimeEscrow
/// @notice Pay a node operator only for the hours a watcher has signed as "up".
///         The customer deploys and funds the escrow in one transaction. Each
///         signed hour pays the operator a fixed rate. Hours nobody signed are
///         returned to the customer after the term ends.
/// @dev    Holds native USDC on Arc, which uses 18 decimals (not 6).
///         An hour is identified by block.timestamp / 3600 (a UTC hour index).
contract UptimeEscrow {
    uint64 public constant GRACE_HOURS = 24;

    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant HOUR_TYPEHASH = keccak256("UptimeHour(uint64 hour)");
    uint256 private constant HALF_ORDER =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    address public immutable customer;
    address public immutable operator;
    address public immutable watcher;
    uint256 public immutable ratePerHour;
    uint64 public immutable startHour;
    uint64 public immutable endHour; // exclusive
    bytes32 public immutable DOMAIN_SEPARATOR;

    mapping(uint64 => bool) public paid;
    uint64 public hoursPaid;
    bool public refunded;

    event Funded(address indexed customer, uint256 amount, uint64 startHour, uint64 endHour);
    event HourPaid(uint64 indexed hour, address indexed operator, uint256 amount);
    event Refunded(address indexed customer, uint256 amount, uint64 hoursUnpaid);

    error ZeroAddress();
    error BadTerm();
    error WrongFunding(uint256 expected, uint256 sent);
    error LengthMismatch();
    error AlreadyRefunded();
    error HourOutsideTerm(uint64 hour);
    error HourNotFinished(uint64 hour);
    error HourAlreadyPaid(uint64 hour);
    error BadSignature(uint64 hour);
    error TooEarlyToRefund(uint64 refundableFromHour);
    error TransferFailed();

    constructor(address _operator, address _watcher, uint256 _ratePerHour, uint64 _startHour, uint64 _endHour)
        payable
    {
        if (_operator == address(0) || _watcher == address(0)) revert ZeroAddress();
        if (_ratePerHour == 0 || _endHour <= _startHour) revert BadTerm();
        uint256 expected = _ratePerHour * (_endHour - _startHour);
        if (msg.value != expected) revert WrongFunding(expected, msg.value);

        customer = msg.sender;
        operator = _operator;
        watcher = _watcher;
        ratePerHour = _ratePerHour;
        startHour = _startHour;
        endHour = _endHour;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("UptimeEscrow"), keccak256("1"), block.chainid, address(this))
        );

        emit Funded(msg.sender, msg.value, _startHour, _endHour);
    }

    /// @notice Pay the operator for finished hours the watcher signed. Anyone may submit.
    function claim(uint64[] calldata hourList, bytes[] calldata signatures) external {
        if (refunded) revert AlreadyRefunded();
        if (hourList.length == 0 || hourList.length != signatures.length) revert LengthMismatch();

        uint64 nowHour = currentHour();
        for (uint256 i = 0; i < hourList.length; i++) {
            uint64 hour = hourList[i];
            if (hour < startHour || hour >= endHour) revert HourOutsideTerm(hour);
            if (hour >= nowHour) revert HourNotFinished(hour);
            if (paid[hour]) revert HourAlreadyPaid(hour);
            if (_recover(hourDigest(hour), signatures[i]) != watcher) revert BadSignature(hour);

            paid[hour] = true;
            emit HourPaid(hour, operator, ratePerHour);
        }

        hoursPaid += uint64(hourList.length);
        _send(operator, ratePerHour * hourList.length);
    }

    /// @notice After the term plus a grace period, return every unpaid hour to the customer.
    function refund() external {
        if (refunded) revert AlreadyRefunded();
        uint64 refundableFrom = endHour + GRACE_HOURS;
        if (currentHour() < refundableFrom) revert TooEarlyToRefund(refundableFrom);

        refunded = true;
        uint256 amount = address(this).balance;
        emit Refunded(customer, amount, (endHour - startHour) - hoursPaid);
        if (amount > 0) _send(customer, amount);
    }

    /// @notice The message the watcher signs for one hour (EIP-712), bound to this chain and this contract.
    function hourDigest(uint64 hour) public view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, keccak256(abi.encode(HOUR_TYPEHASH, hour))));
    }

    function currentHour() public view returns (uint64) {
        return uint64(block.timestamp / 3600);
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (uint256(s) > HALF_ORDER || (v != 27 && v != 28)) return address(0);
        return ecrecover(digest, v, r, s);
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
