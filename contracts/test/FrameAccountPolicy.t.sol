// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FrameAccountPolicy} from "../src/FrameAccountPolicy.sol";

contract FrameAccountPolicyTest is Test {
    using FrameAccountPolicy for *;

    address constant A = address(0xA);
    address constant B = address(0xB);
    address constant C = address(0xC);
    address constant D = address(0xD);

    function _owners3() internal pure returns (address[] memory o) {
        o = new address[](3);
        (o[0], o[1], o[2]) = (A, B, C);
    }

    function _addrs(address x) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = x;
    }

    function _addrs(address x, address y) internal pure returns (address[] memory a) {
        a = new address[](2);
        (a[0], a[1]) = (x, y);
    }

    // --- countDistinctOwners -------------------------------------------------

    function test_countsOnlyOwners() public pure {
        assertEq(FrameAccountPolicy.countDistinctOwners(_addrs(A, B), _owners3()), 2);
        assertEq(FrameAccountPolicy.countDistinctOwners(_addrs(A, D), _owners3()), 1);
        assertEq(FrameAccountPolicy.countDistinctOwners(_addrs(D), _owners3()), 0);
    }

    /// A repeated signer must not count twice. This is the check that stops one
    /// key from single-handedly satisfying a k-of-n threshold by appearing in
    /// several signature entries.
    function test_duplicateSignerCountsOnce() public pure {
        assertEq(FrameAccountPolicy.countDistinctOwners(_addrs(A, A), _owners3()), 1);
        address[] memory many = new address[](4);
        (many[0], many[1], many[2], many[3]) = (A, A, A, B);
        assertEq(FrameAccountPolicy.countDistinctOwners(many, _owners3()), 2);
    }

    function test_emptyInputs() public pure {
        address[] memory none = new address[](0);
        assertEq(FrameAccountPolicy.countDistinctOwners(none, _owners3()), 0);
        assertEq(FrameAccountPolicy.countDistinctOwners(_addrs(A), none), 0);
    }

    // --- meetsThreshold ------------------------------------------------------

    function test_thresholdBoundaries() public pure {
        assertFalse(FrameAccountPolicy.meetsThreshold(_addrs(A), _owners3(), 2));
        assertTrue(FrameAccountPolicy.meetsThreshold(_addrs(A, B), _owners3(), 2));
        assertTrue(FrameAccountPolicy.meetsThreshold(_addrs(A, B), _owners3(), 1));
    }

    /// A zero threshold must never authorise, or an account with a misconfigured
    /// threshold would approve transactions nobody signed.
    function test_zeroThresholdNeverAuthorises() public pure {
        address[] memory none = new address[](0);
        assertFalse(FrameAccountPolicy.meetsThreshold(none, _owners3(), 0));
        assertFalse(FrameAccountPolicy.meetsThreshold(_addrs(A, B), _owners3(), 0));
    }

    /// Duplicates must not be able to reach a threshold on their own.
    function testFuzz_duplicatesCannotReachThreshold(uint8 repeats) public pure {
        repeats = uint8(bound(repeats, 1, 32));
        address[] memory signers = new address[](repeats);
        for (uint256 i = 0; i < repeats; i++) {
            signers[i] = A;
        }
        assertTrue(FrameAccountPolicy.meetsThreshold(signers, _owners3(), 1));
        assertFalse(FrameAccountPolicy.meetsThreshold(signers, _owners3(), 2));
    }

    /// The count can never exceed the number of owners, however many signers
    /// are supplied.
    function testFuzz_countBoundedByOwnerSet(address[] memory signers) public pure {
        vm.assume(signers.length <= 64);
        uint256 n = FrameAccountPolicy.countDistinctOwners(signers, _owners3());
        assertLe(n, 3);
    }

    // --- sessionKeyAllowsCall ------------------------------------------------

    function _key(uint64 until, bool allowValue)
        internal
        pure
        returns (FrameAccountPolicy.SessionKey memory)
    {
        return FrameAccountPolicy.SessionKey({validUntil: until, allowValue: allowValue});
    }

    function test_sessionKeyHappyPath() public pure {
        assertTrue(FrameAccountPolicy.sessionKeyAllowsCall(_key(1000, false), 999, C, 0, _addrs(C)));
    }

    /// An unregistered key has validUntil == 0 and must be rejected even when the
    /// timestamp is also zero -- otherwise "expired" and "never registered" would
    /// be indistinguishable and a zero timestamp would authorise.
    function test_unregisteredKeyRejectedAtZeroTimestamp() public pure {
        assertFalse(FrameAccountPolicy.sessionKeyAllowsCall(_key(0, true), 0, C, 0, _addrs(C)));
    }

    function test_sessionKeyExpiryIsInclusive() public pure {
        // Valid exactly at the deadline, invalid one second later.
        assertTrue(
            FrameAccountPolicy.sessionKeyAllowsCall(_key(1000, false), 1000, C, 0, _addrs(C))
        );
        assertFalse(
            FrameAccountPolicy.sessionKeyAllowsCall(_key(1000, false), 1001, C, 0, _addrs(C))
        );
    }

    function test_sessionKeyValueAndAllowlist() public pure {
        // Value blocked unless explicitly permitted.
        assertFalse(FrameAccountPolicy.sessionKeyAllowsCall(_key(1000, false), 1, C, 1, _addrs(C)));
        assertTrue(FrameAccountPolicy.sessionKeyAllowsCall(_key(1000, true), 1, C, 1, _addrs(C)));
        // Target must be allowlisted.
        assertFalse(FrameAccountPolicy.sessionKeyAllowsCall(_key(1000, true), 1, D, 0, _addrs(C)));
    }

    function testFuzz_sessionKeyNeverAllowsUnlistedTarget(address target, uint256 value)
        public
        pure
    {
        vm.assume(target != C && target != B);
        assertFalse(
            FrameAccountPolicy.sessionKeyAllowsCall(
                _key(type(uint64).max, true), 1, target, value, _addrs(C, B)
            )
        );
    }

    // --- selectorOf ----------------------------------------------------------

    /// framedataload returns the selector left-aligned in a 32-byte word, so it
    /// must be read from the high bytes. Getting this backwards silently matches
    /// the wrong function.
    function test_selectorTakenFromHighBytes() public pure {
        bytes memory callData = abi.encodeWithSignature("transfer(address,uint256)", A, 1);
        bytes32 firstWord;
        assembly {
            firstWord := mload(add(callData, 0x20))
        }
        assertEq(
            FrameAccountPolicy.selectorOf(firstWord, callData.length),
            bytes4(keccak256("transfer(address,uint256)"))
        );
    }

    /// A frame carrying fewer than 4 bytes has no selector; the opcode
    /// zero-extends, which must not be mistaken for a real selector value.
    function test_shortDataHasNoSelector() public pure {
        assertEq(FrameAccountPolicy.selectorOf(bytes32(uint256(1) << 248), 3), bytes4(0));
    }
}
