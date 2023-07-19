// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import 'forge-std/Test.sol';
import '../contracts/Ibc.sol';
import {Dispatcher, InitClientMsg, UpgradeClientMsg} from '../contracts/Dispatcher.sol';
import {IbcReceiver} from '../contracts/IbcReceiver.sol';
import '../contracts/IbcVerifier.sol';
import '../contracts/Verifier.sol';
import '../contracts/Mars.sol';

contract Base is Test {
    //
    // channel events
    //

    event OpenIbcChannel(
        address indexed portAddress,
        string version,
        ChannelOrder ordering,
        string[] connectionHops,
        string counterpartyPortId,
        bytes32 counterpartyChannelId
    );

    event ConnectIbcChannel(address indexed portAddress, bytes32 channelId);

    event CloseIbcChannel(address indexed portAddress, bytes32 indexed channelId);

    //
    // packet events
    //

    event SendPacket(
        address indexed sourcePortAddress,
        bytes32 indexed sourceChannelId,
        bytes packet,
        uint64 sequence,
        // timeoutTimestamp is in UNIX nano seconds; packet will be rejected if
        // delivered after this timestamp on the receiving chain.
        // Timeout semantics is compliant to IBC spec and ibc-go implementation
        uint64 timeoutTimestamp,
        PacketFee fee
    );

    event Acknowledgement(address indexed sourcePortAddress, bytes32 indexed sourceChannelId, uint64 sequence);

    event Timeout(address indexed sourcePortAddress, bytes32 indexed sourceChannelId, uint64 indexed sequence);

    event RecvPacket(address indexed destPortAddress, bytes32 indexed destChannelId, uint64 sequence);

    event WriteAckPacket(
        address indexed writerPortAddress,
        bytes32 indexed writerChannelId,
        uint64 sequence,
        AckPacket ackPacket
    );

    event WriteTimeoutPacket(address indexed writerPortAddress, bytes32 indexed writerChannelId, uint64 sequence);

    ConsensusState untrustedState =
        ConsensusState(
            80990,
            590199110038530808131927832294665177527506259518072095333098842116767351199,
            7000040,
            1000
        );
    ConsensusState trustedState =
        ConsensusState(
            10934,
            7064503680087416120706887577693908749828198688716609274705703517077803898371,
            7002040,
            1020
        );
    InitClientMsg initClientMsg = InitClientMsg(bytes('Polymer'), untrustedState);

    ZKMintVerifier verifier = new Verifier();
    ZkProof proof =
        ZkProof(
            [
                13449388914393258752883032560537386278857542833249142697090243871249761501123,
                5963894333042515966217276339656894890750758020607775733717462915787234629927
            ],
            [
                [
                    4811559872397934450173412387101758297072581261546553338353504577141293696514,
                    18400634037991283592418145553628778322894277765243742619561207628896194710939
                ],
                [
                    17903685207039300384995795331083569887497623740119108595975170464164316221644,
                    9246628133289276308945311797896077179503891414159382179119544904154776510385
                ]
            ],
            [
                17432552394458345841788798376121543520587716339044416231610790827968220675517,
                15082220514596158133191868403239442750535261032426474092101151620016661078026
            ]
        );
    address payable escrow = payable(vm.addr(uint256(keccak256(abi.encode('escrow')))));

    Dispatcher dispatcher;
}

contract DispatcherCreateClientTest is Test, Base {
    function setUp() public {
        dispatcher = new Dispatcher(verifier, escrow, 'polyibc.eth.');
    }

    function test_success() public {
        dispatcher.createClient(initClientMsg);
    }

    function test_mustByOwner() public {
        vm.prank(vm.addr(0x1));
        vm.expectRevert('Ownable: caller is not the owner');
        dispatcher.createClient(initClientMsg);
    }

    function test_onlyOnce() public {
        dispatcher.createClient(initClientMsg);
        vm.expectRevert('Client already created');
        dispatcher.createClient(initClientMsg);
    }
}

contract DispatcherUpdateClientTest is Test, Base {
    function setUp() public {
        dispatcher = new Dispatcher(verifier, escrow, 'polyibc.eth.');
        dispatcher.createClient(initClientMsg);
    }

    function test_success() public {
        dispatcher.updateClient(UpdateClientMsg(trustedState, proof));
    }

    function test_invalidConsensusState() public {
        vm.expectRevert('UpdateClientMsg proof verification failed');
        dispatcher.updateClient(UpdateClientMsg(untrustedState, proof));
        vm.expectRevert('UpdateClientMsg proof verification failed');
        ConsensusState memory invalidConsensusState;
        dispatcher.updateClient(UpdateClientMsg(invalidConsensusState, proof));
    }
}

contract DispatcherUpgradeClientTest is Test, Base {
    function setUp() public {
        dispatcher = new Dispatcher(verifier, escrow, 'polyibc.eth.');
        dispatcher.createClient(initClientMsg);
        dispatcher.updateClient(UpdateClientMsg(trustedState, proof));
    }

    function test_success() public {
        dispatcher.upgradeClient(UpgradeClientMsg(bytes('upgradeClientState'), trustedState));
    }

    function test_ownerOnly() public {
        vm.prank(vm.addr(0x1));
        vm.expectRevert('Ownable: caller is not the owner');
        dispatcher.upgradeClient(UpgradeClientMsg(bytes('upgradeClientState'), trustedState));
    }
}

struct VersionSet {
    string self;
    string counterparty;
    string expected;
}

contract DispatcherOpenIbcChannelTest is Test, Base {
    Mars mars = new Mars();
    Proof polymerProof = Proof(42, bytes('valid proof'));
    string[] connectionHops;
    VersionSet version;
    ChannelOrder ordering;
    CounterParty cp;

    function setUp() public {
        connectionHops = new string[](2);
        connectionHops[0] = 'connection-1';
        connectionHops[1] = 'connection-2';

        dispatcher = new Dispatcher(verifier, escrow, 'polyibc.eth.');
        dispatcher.createClient(initClientMsg);
        dispatcher.updateClient(UpdateClientMsg(trustedState, proof));
        vm.startPrank(vm.addr(0x1));
    }

    modifier goodCases() {
        // NOTE: counterparty version is set in VersionSet
        ChannelOrder[2] memory orderings = [ChannelOrder.ORDERED, ChannelOrder.UNORDERED];
        // 1st handshake with unknown counterparty version or channelId
        cp = CounterParty('polyibc.bsc.9876543210', bytes32(0x0), '');
        VersionSet[2] memory versions = [VersionSet('1.0', '', '1.0'), VersionSet('2.0', '', '2.0')];
        for (uint i = 0; i < versions.length; i++) {
            for (uint j = 0; j < orderings.length; j++) {
                version = versions[i];
                cp.version = version.counterparty;
                ordering = orderings[j];
                _;
            }
        }
        // 2nd handshake with known counterparty version and channelId
        cp = CounterParty('polyibc.bsc.9876543210', bytes32('channel-99'), '');
        versions = [VersionSet('', '1.0', '1.0'), VersionSet('', '2.0', '2.0')];
        for (uint i = 0; i < versions.length; i++) {
            for (uint j = 0; j < orderings.length; j++) {
                version = versions[i];
                cp.version = version.counterparty;
                ordering = orderings[j];
                _;
            }
        }
    }

    function test_success() public goodCases {
        vm.expectEmit(true, true, true, true);
        emit OpenIbcChannel(address(mars), version.expected, ordering, connectionHops, cp.portId, cp.channelId);
        dispatcher.openIbcChannel(IbcReceiver(mars), version.self, ordering, connectionHops, cp, polymerProof);
    }

    function test_unsupportedVersion() public {
        cp = CounterParty('polyibc.bsc.9876543210', bytes32(0x0), '');
        vm.expectRevert('Unsupported version');
        dispatcher.openIbcChannel(
            IbcReceiver(mars),
            'unsupported-version',
            ChannelOrder.ORDERED,
            connectionHops,
            cp,
            polymerProof
        );
    }
}

contract DispatcherTest is Test, Base {
    function setUp() public {}
}
