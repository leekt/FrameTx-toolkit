// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FrameTest, IFrameVm} from "./FrameTest.sol";

interface IHarness {
    function txNonce() external view returns (uint256);
    function txSender() external view returns (address);
    function maxCost() external view returns (uint256);
    function sigHash() external view returns (bytes32);
    function frameCount() external view returns (uint256);
    function currentFrameIndex() external view returns (uint256);
    function signatureCount() external view returns (uint256);
    function frameTarget(uint256 i) external view returns (address);
    function frameGasLimit(uint256 i) external view returns (uint256);
    function frameMode(uint256 i) external view returns (uint256);
    function frameFlags(uint256 i) external view returns (uint256);
    function frameDataLength(uint256 i) external view returns (uint256);
    function frameStatus(uint256 i) external view returns (uint256);
    function frameAllowedScope(uint256 i) external view returns (uint256);
    function frameIsAtomicBatch(uint256 i) external view returns (bool);
    function frameValue(uint256 i) external view returns (uint256);
    function frameDataLoad(uint256 i, uint256 offset) external view returns (bytes32);
    function frameDataSlice(uint256 i, uint256 offset, uint256 length)
        external
        view
        returns (bytes memory);
    function frameData(uint256 i) external view returns (bytes memory);
    function sigSigner(uint256 i) external view returns (address);
    function sigScheme(uint256 i) external view returns (uint256);
    function sigMsg(uint256 i) external view returns (bytes32);
    function signedThisTx(uint256 i) external view returns (bool);
    function sigLength(uint256 i) external view returns (uint256);
    function sigDataSlice(uint256 i, uint256 offset, uint256 length)
        external
        view
        returns (bytes memory);
    function sigData(uint256 i) external view returns (bytes memory);
    function approve(uint256 scope) external;
}

/// Every FrameTxLib wrapper executed against the real opcodes, pinned to a
/// fixture rich enough that a swapped operand or off-by-one index cannot pass.
contract FrameTxLibTest is FrameTest {
    address constant HARNESS = address(0x11B);
    IHarness constant h = IHarness(HARNESS);

    bytes constant FRAME0_DATA = hex"6901f668";
    bytes constant FRAME1_DATA =
        hex"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff0102";
    bytes constant ARB_SIG =
        hex"deadbeef00000000000000000000000000000000000000000000000000000000c0ffee";
    address constant SIGNER = address(0x0BEEF);
    bytes32 constant SIG_HASH = keccak256("sig hash");
    bytes32 constant OTHER_MSG = keccak256("some other digest");

    function setUp() public {
        deployAccount("FrameTxLibHarness", HARNESS);
    }

    /// Two frames -- frame 0 already succeeded, frame 1 (current) carries value
    /// and data -- and two signatures: a protocol-verified secp256k1 entry over
    /// this transaction and an ARBITRARY entry with an explicit msg.
    function _ctx() internal pure returns (IFrameVm.FrameTx memory ctx) {
        IFrameVm.FrameTxFrame[] memory frames = new IFrameVm.FrameTxFrame[](2);
        frames[0] = IFrameVm.FrameTxFrame({
            mode: MODE_VERIFY,
            flags: 0x3,
            target: address(0xACC0),
            gasLimit: 100_000,
            value: 0,
            data: FRAME0_DATA,
            status: 1
        });
        frames[1] = IFrameVm.FrameTxFrame({
            mode: MODE_DEFAULT,
            // Bit 2 set: part of an atomic batch. Low bits 0: no approvals.
            flags: 0x4,
            target: HARNESS,
            gasLimit: 500_000,
            value: 42 ether,
            data: FRAME1_DATA,
            status: 0
        });

        IFrameVm.FrameTxSignature[] memory sigs = new IFrameVm.FrameTxSignature[](2);
        sigs[0] = IFrameVm.FrameTxSignature({
            scheme: 1, signer: SIGNER, msgHash: bytes32(0), signature: ""
        });
        sigs[1] = IFrameVm.FrameTxSignature({
            scheme: 0, signer: address(0), msgHash: OTHER_MSG, signature: ARB_SIG
        });

        ctx = IFrameVm.FrameTx({
            sender: address(0xACC0),
            nonce: 7,
            sigHash: SIG_HASH,
            maxCost: 1 ether,
            frameIndex: 1,
            approvableScopes: SCOPE_BOTH,
            frames: frames,
            signatures: sigs
        });
    }

    modifier inFrame() {
        fvm.setFrameTx(_ctx());
        _;
        fvm.clearFrameTx();
    }

    function test_txScope() public inFrame {
        assertEq(h.txNonce(), 7, "nonce");
        assertEq(h.txSender(), address(0xACC0), "sender");
        assertEq(h.maxCost(), 1 ether, "maxCost");
        assertEq(h.sigHash(), SIG_HASH, "sigHash");
        assertEq(h.frameCount(), 2, "frameCount");
        assertEq(h.currentFrameIndex(), 1, "currentFrameIndex");
        assertEq(h.signatureCount(), 2, "signatureCount");
    }

    function test_frameScope() public inFrame {
        assertEq(h.frameTarget(0), address(0xACC0), "frame 0 target");
        assertEq(h.frameMode(0), 1, "frame 0 mode VERIFY");
        assertEq(h.frameFlags(0), 0x3, "frame 0 flags");
        assertEq(h.frameAllowedScope(0), 3, "frame 0 allowed scope");
        assertEq(h.frameStatus(0), 1, "frame 0 status SUCCESS");
        assertFalse(h.frameIsAtomicBatch(0), "frame 0 not atomic");

        assertEq(h.frameTarget(1), HARNESS, "frame 1 target");
        assertEq(h.frameMode(1), 0, "frame 1 mode DEFAULT");
        assertEq(h.frameGasLimit(1), 500_000, "frame 1 gas limit");
        assertEq(h.frameValue(1), 42 ether, "frame 1 value");
        assertEq(h.frameAllowedScope(1), 0, "frame 1 allowed scope");
        assertTrue(h.frameIsAtomicBatch(1), "frame 1 atomic");
    }

    function test_frameData() public inFrame {
        assertEq(h.frameDataLength(1), FRAME1_DATA.length, "frame 1 data length");
        assertEq(h.frameData(1), FRAME1_DATA, "frame 1 full data");
        assertEq(h.frameData(0), FRAME0_DATA, "frame 0 full data");
        // A word loaded straight, a word loaded past the end (zero-padded),
        // and a slice crossing the end.
        assertEq(
            h.frameDataLoad(1, 0),
            bytes32(0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff),
            "word at 0"
        );
        assertEq(
            h.frameDataLoad(1, 32),
            bytes32(0x0102000000000000000000000000000000000000000000000000000000000000),
            "word at 32 zero-padded"
        );
        assertEq(
            h.frameDataSlice(1, 32, 4),
            abi.encodePacked(hex"0102", new bytes(2)),
            "slice crossing the end zero-filled"
        );
    }

    function test_sigScope() public inFrame {
        assertEq(h.sigScheme(0), 1, "sig 0 scheme SECP256K1");
        assertEq(h.sigSigner(0), SIGNER, "sig 0 resolved signer");
        assertEq(h.sigMsg(0), bytes32(0), "sig 0 msg");
        assertTrue(h.signedThisTx(0), "sig 0 signed this tx");

        assertEq(h.sigScheme(1), 0, "sig 1 scheme ARBITRARY");
        assertEq(h.sigMsg(1), OTHER_MSG, "sig 1 explicit msg");
        assertFalse(h.signedThisTx(1), "sig 1 signed something else");
    }

    /// The raw-bytes read behind sigData is SIGPARAM's copy form -- the
    /// sigdatacopy builtin -- executed end to end against revm.
    function test_sigData() public inFrame {
        assertEq(h.sigLength(1), ARB_SIG.length, "sig 1 length");
        assertEq(h.sigData(1), ARB_SIG, "sig 1 full bytes");
        assertEq(h.sigDataSlice(1, 32, 3), hex"c0ffee", "sig 1 tail slice");
        assertEq(
            h.sigDataSlice(1, 32, 8),
            abi.encodePacked(hex"c0ffee", new bytes(5)),
            "sig 1 slice zero-filled"
        );
    }

    /// Reading the raw bytes of a protocol-verified entry must halt: the spec
    /// keeps those opaque so schemes can be aggregated later.
    function test_sigDataOfProtocolSchemeHalts() public inFrame {
        (bool ok,) = HARNESS.call(abi.encodeCall(IHarness.sigData, (0)));
        assertFalse(ok, "copying SECP256K1 bytes must fail");
    }

    /// Asking an ARBITRARY entry for its resolved signer must halt: there is
    /// none -- the protocol verified nothing.
    function test_sigSignerOfArbitraryHalts() public inFrame {
        (bool ok,) = HARNESS.call(abi.encodeCall(IHarness.sigSigner, (1)));
        assertFalse(ok, "resolved signer of ARBITRARY must fail");
    }

    /// The status of the current frame is not readable.
    function test_currentFrameStatusHalts() public inFrame {
        (bool ok,) = HARNESS.call(abi.encodeCall(IHarness.frameStatus, (1)));
        assertFalse(ok, "status of the current frame must fail");
    }

    function test_approve() public {
        IFrameVm.FrameTx memory ctx = verifyContext(HARNESS, SCOPE_BOTH, SIG_HASH);
        ctx.frames[0].data = abi.encodeCall(IHarness.approve, (SCOPE_BOTH));
        assertApprovesFrame(HARNESS, ctx, "approve(SCOPE_BOTH) should succeed");
    }

    function test_approveBeyondAllowedScopeFails() public {
        IFrameVm.FrameTx memory ctx = verifyContext(HARNESS, SCOPE_PAYMENT, SIG_HASH);
        ctx.frames[0].data = abi.encodeCall(IHarness.approve, (SCOPE_BOTH));
        assertRefusesFrame(HARNESS, ctx, "scope must be a subset of the frame's flags");
    }
}
