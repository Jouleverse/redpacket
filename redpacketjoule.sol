// SPDX-License-Identifier: MIT
// Author: Evan Liu <evan@blockcoach.com>
// ver 0.1, 2023.11.12. first version ready for review.
pragma solidity ^0.8.0;

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IERC721 {
    function balanceOf(address owner) external view returns (uint256 balance);
}

// Owner-free
contract RedPacketJoule {
    IERC20 public WJ; 
    IERC721 public JTI;

    struct OpenedPacket {
        uint256 e;
        address opener;
        uint256 block_height;
    }

    struct RedPacket {
        bool created; //trick for checking existence
        address creator;
        uint256 expiry;
        uint256 total_e;
        uint256 total_n;
        uint256 left_e;
        uint256 left_n;
        uint256 final_e; //how much were opened at last
        uint256 final_n; //how many were opened at last
        uint256 last_seed;
        mapping(uint256 => OpenedPacket) opened;
        mapping(address => bool) openers; // each one can only open once
    }

    mapping(uint256 => RedPacket) public redpackets;

    constructor (address _wj, address _jti) {
        WJ = IERC20(_wj);
        JTI = IERC721(_jti);
    }

    function create(uint256 id, uint256 quantity, uint256 amount) public {
        require(redpackets[id].created == false, "ERROR: redpacket already created");
        require(quantity <= 500, "ERROR: too many red packets"); //hard-coded 500
        require(amount <= 2000 * 10**18, "ERROR: too much Joule"); //hard-coded 2000
        require(amount >= quantity, "ERROR: too few Joule");

        require(WJ.transferFrom(msg.sender, address(this), amount), "ERROR: failed to transfer enough tokens in");

        redpackets[id].created = true;
        redpackets[id].creator = msg.sender;
        redpackets[id].expiry = block.number + (24 hours / 15);
        redpackets[id].total_e = amount;
        redpackets[id].total_n = quantity;
        redpackets[id].left_e = amount;
        redpackets[id].left_n = quantity;
    }

    function open(uint256 id, uint256 lucky_n) public {
        require(JTI.balanceOf(msg.sender) > 0, "ERROR: identity not authenticated");
        require(redpackets[id].openers[msg.sender] == false, "ERROR: cannot open twice");

        require(redpackets[id].left_e > 0 && redpackets[id].left_n > 0, "ERROR: nothing left");
        require(block.number < redpackets[id].expiry, "ERROR: expired");
        
        uint256 e;
        if (redpackets[id].left_n == 1) {
            e = redpackets[id].left_e;
        } else {
            uint256 seed = uint256(keccak256(abi.encodePacked(lucky_n, msg.sender, blockhash(block.number - 1), redpackets[id].last_seed)));
            redpackets[id].last_seed = seed;
            e = seed % (2 * redpackets[id].left_e / redpackets[id].left_n);
            if (e == 0)
                e = 1; //guarantee at least 1 e in each packet
        }

        // update
        redpackets[id].left_e -= e;
        redpackets[id].left_n -= 1;

        uint256 n = redpackets[id].final_n;
        redpackets[id].opened[n].e = e;
        redpackets[id].opened[n].opener = msg.sender;
        redpackets[id].opened[n].block_height = block.number;

        redpackets[id].final_e += e;
        redpackets[id].final_n += 1;

        redpackets[id].openers[msg.sender] = true;

        // deliver the red packet
        WJ.transferFrom(address(this), msg.sender, e);
        // TODO: should we use event to log it here?
    }

    function inspect(uint256 id, uint256 n) public view returns (OpenedPacket memory) {
        return redpackets[id].opened[n];
    }

    function withdraw(uint256 id) public {
        require(msg.sender == redpackets[id].creator, "ERROR: only creator can withdraw");
        require(redpackets[id].left_e > 0 && redpackets[id].left_n > 0, "ERROR: nothing left");
        require(block.number >= redpackets[id].expiry, "ERROR: not yet expired");

        uint256 left_e = redpackets[id].left_e;

        // clear
        redpackets[id].left_e = 0;
        redpackets[id].left_n = 0;
        // after clearing, you may check final_e and final_n for references

        // do withdraw
        WJ.transferFrom(address(this), msg.sender, left_e);
    }
}

