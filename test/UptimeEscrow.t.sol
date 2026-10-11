// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UptimeEscrow} from "../src/UptimeEscrow.sol";

contract UptimeEscrowTest is Test {
    // Native USDC on Arc has 18 decimals, so 0.05 ether here means 5 cents.
    uint256 constant RATE = 0.05 ether;
    uint64 constant START = 500_000;
    uint64 constant END = 500_020; // 20 hours, 1 USDC total

    address customer = makeAddr("customer");
    address operator = makeAddr("operator");
    address stranger = makeAddr("stranger");
    uint256 watcherKey = 0xA11CE;
    uint256 imposterKey = 0xB0B;
    address watcher;

    UptimeEscrow escrow;

    function setUp() public {
        watcher = vm.addr(watcherKey);
        vm.deal(customer, 10 ether);
        vm.warp(uint256(START) * 3600);
        escrow = _deploy();
    }

    // ---------- helpers ----------

    function _deploy() internal returns (UptimeEscrow e) {
        vm.prank(customer);
        e = new UptimeEscrow{value: RATE * (END - START)}(operator, watcher, RATE, START, END);
    }

    function _sign(UptimeEscrow e, uint256 key, uint64 hour) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, e.hourDigest(hour));
        return abi.encodePacked(r, s, v);
    }

    function _one(uint64 hour, bytes memory sig) internal pure returns (uint64[] memory h, bytes[] memory s) {
        h = new uint64[](1);
        s = new bytes[](1);
        h[0] = hour;
        s[0] = sig;
    }

    function _toHour(uint64 hour) internal {
        vm.warp(uint256(hour) * 3600);
    }

    // ---------- deploy ----------

    function test_deploy_records_terms_and_funds() public view {
        assertEq(escrow.customer(), customer);
        assertEq(address(escrow).balance, 1 ether);
    }

    function test_deploy_rejects_wrong_funding() public {
        vm.prank(customer);
        vm.expectRevert(abi.encodeWithSelector(UptimeEscrow.WrongFunding.selector, 1 ether, 0.5 ether));
        new UptimeEscrow{value: 0.5 ether}(operator, watcher, RATE, START, END);
    }

    function test_deploy_rejects_zero_address() public {
        vm.prank(customer);
        vm.expectRevert(UptimeEscrow.ZeroAddress.selector);
        new UptimeEscrow{value: 1 ether}(address(0), watcher, RATE, START, END);
    }

    function test_deploy_rejects_bad_term() public {
        vm.prank(customer);
        vm.expectRevert(UptimeEscrow.BadTerm.selector);
        new UptimeEscrow{value: 0}(operator, watcher, RATE, END, START);
    }

    // ---------- claim ----------

    function test_signed_hour_pays_operator() public {
        _toHour(START + 1);
        (uint64[] memory h, bytes[] memory s) = _one(START, _sign(escrow, watcherKey, START));
        escrow.claim(h, s);
        assertEq(operator.balance, RATE);
        assertTrue(escrow.paid(START));
        assertEq(escrow.hoursPaid(), 1);
    }

    function test_anyone_can_submit_but_operator_gets_paid() public {
        _toHour(START + 1);
        (uint64[] memory h, bytes[] memory s) = _one(START, _sign(escrow, watcherKey, START));
        vm.prank(stranger);
        escrow.claim(h, s);
        assertEq(operator.balance, RATE);
        assertEq(stranger.balance, 0);
    }

    function test_batch_claim_pays_every_hour() public {
        _toHour(START + 5);
        uint64[] memory h = new uint64[](5);
        bytes[] memory s = new bytes[](5);
        for (uint64 i = 0; i < 5; i++) {
            h[i] = START + i;
            s[i] = _sign(escrow, watcherKey, START + i);
        }
        escrow.claim(h, s);
        assertEq(operator.balance, RATE * 5);
    }

    function test_unsigned_hour_rejected() public {
        _toHour(START + 1);
        (uint64[] memory h, bytes[] memory s) = _one(START, "");
        vm.expectRevert(abi.encodeWithSelector(UptimeEscrow.BadSignature.selector, START));
        escrow.claim(h, s);
    }

    function test_wrong_signer_rejected() public {
        _toHour(START + 1);
        (uint64[] memory h, bytes[] memory s) = _one(START, _sign(escrow, imposterKey, START));
        vm.expectRevert(abi.encodeWithSelector(UptimeEscrow.BadSignature.selector, START));
        escrow.claim(h, s);
    }

    function test_signature_for_other_hour_rejected() public {
        _toHour(START + 2);
        (uint64[] memory h, bytes[] memory s) = _one(START, _sign(escrow, watcherKey, START + 1));
        vm.expectRevert(abi.encodeWithSelector(UptimeEscrow.BadSignature.selector, START));
        escrow.claim(h, s);
    }

    function test_signature_from_other_contract_rejected() public {
        UptimeEscrow other = _deploy();
        _toHour(START + 1);
        (uint64[] memory h, bytes[] memory s) = _one(START, _sign(other, watcherKey, START));
        vm.expectRevert(abi.encodeWithSelector(UptimeEscrow.BadSignature.selector, START));
        escrow.claim(h, s);
    }

    function test_same_hour_twice_rejected() public {
        _toHour(START + 1);
        (uint64[] memory h, bytes[] memory s) = _one(START, _sign(escrow, watcherKey, START));
        escrow.claim(h, s);
        vm.expectRevert(abi.encodeWithSelector(UptimeEscrow.HourAlreadyPaid.selector, START));
        escrow.claim(h, s);
    }

    function test_same_hour_twice_in_one_batch_rejected() public {
        _toHour(START + 1);
        bytes memory sig = _sign(escrow, watcherKey, START);
        uint64[] memory h = new uint64[](2);
        bytes[] memory s = new bytes[](2);
        h[0] = START;
        h[1] = START;
        s[0] = sig;
        s[1] = sig;
        vm.expectRevert(abi.encodeWithSelector(UptimeEscrow.HourAlreadyPaid.selector, START));
        escrow.claim(h, s);
    }

    function test_hour_before_term_rejected() public {
        _toHour(START + 1);
        (uint64[] memory h, bytes[] memory s) = _one(START - 1, _sign(escrow, watcherKey, START - 1));
        vm.expectRevert(abi.encodeWithSelector(UptimeEscrow.HourOutsideTerm.selector, START - 1));
        escrow.claim(h, s);
    }

    function test_hour_after_term_rejected() public {
        _toHour(END + 1);
        (uint64[] memory h, bytes[] memory s) = _one(END, _sign(escrow, watcherKey, END));
        vm.expectRevert(abi.encodeWithSelector(UptimeEscrow.HourOutsideTerm.selector, END));
        escrow.claim(h, s);
    }

    function test_unfinished_hour_rejected() public {
        _toHour(START + 3);
        (uint64[] memory h, bytes[] memory s) = _one(START + 3, _sign(escrow, watcherKey, START + 3));
        vm.expectRevert(abi.encodeWithSelector(UptimeEscrow.HourNotFinished.selector, START + 3));
        escrow.claim(h, s);
    }

    function test_mismatched_lengths_rejected() public {
        uint64[] memory h = new uint64[](2);
        bytes[] memory s = new bytes[](1);
        vm.expectRevert(UptimeEscrow.LengthMismatch.selector);
        escrow.claim(h, s);
    }

    // ---------- refund ----------

    function test_refund_blocked_before_term_ends() public {
        _toHour(END);
        vm.expectRevert(abi.encodeWithSelector(UptimeEscrow.TooEarlyToRefund.selector, END + 24));
        escrow.refund();
    }

    function test_refund_blocked_during_grace() public {
        _toHour(END + 23);
        vm.expectRevert(abi.encodeWithSelector(UptimeEscrow.TooEarlyToRefund.selector, END + 24));
        escrow.refund();
    }

    function test_refund_returns_exactly_unpaid_hours() public {
        _toHour(START + 3);
        uint64[] memory h = new uint64[](3);
        bytes[] memory s = new bytes[](3);
        for (uint64 i = 0; i < 3; i++) {
            h[i] = START + i;
            s[i] = _sign(escrow, watcherKey, START + i);
        }
        escrow.claim(h, s);

        uint256 before = customer.balance;
        _toHour(END + 24);
        vm.prank(stranger);
        escrow.refund();

        assertEq(customer.balance - before, RATE * 17);
        assertEq(operator.balance, RATE * 3);
        assertEq(address(escrow).balance, 0);
    }

    function test_no_claims_or_second_refund_after_refund() public {
        _toHour(END + 24);
        escrow.refund();

        (uint64[] memory h, bytes[] memory s) = _one(START, _sign(escrow, watcherKey, START));
        vm.expectRevert(UptimeEscrow.AlreadyRefunded.selector);
        escrow.claim(h, s);

        vm.expectRevert(UptimeEscrow.AlreadyRefunded.selector);
        escrow.refund();
    }

    // ---------- fuzz ----------

    function testFuzz_paid_plus_refund_equals_deposit(uint8 hoursUp) public {
        uint64 n = uint64(bound(hoursUp, 1, END - START));
        _toHour(END);
        uint64[] memory h = new uint64[](n);
        bytes[] memory s = new bytes[](n);
        for (uint64 i = 0; i < n; i++) {
            h[i] = START + i;
            s[i] = _sign(escrow, watcherKey, START + i);
        }
        escrow.claim(h, s);

        uint256 before = customer.balance;
        _toHour(END + 24);
        escrow.refund();
        assertEq(operator.balance + (customer.balance - before), 1 ether);
    }
}
