# redpacket
on-chain red packet implementation
链上红包的实现方案

## 基本思路

* 把wJ放到红包合约中锁定供领取。（方案一: 锁入 wJ转换为J 放在合约中；提出 J转换为wJ 给出去。方案二：支持任意ERC-20）
* 一个合约，多批红包。每批红包有自己的hash。前端支持的时候使用类似于 /redpacket/合约地址/红包id（uint256 hash值） 的方式来定位到具体某一批红包。用hash而不是顺序序列号作为id是为了防止简单猜测就能找到其他批次的红包（由于链上数据透明，这是防君子不防小人）。
* 一次交易上链完成wJ的存入和红包的创建。创建人需要先授权红包合约扣除其地址中的wJ。创建人设定红包总量（XX J，限制为0.01（含） - 2000 J（含）之间）以及这一批的红包个数（YY 个 —— 为简化，限制为 1（含） 到 500（含） 之间）。每个红包含多少J是创建时就预计算好的（链下完成，不是由链上智能合约计算的），而且每个红包的大小（J的含量）是随机划分的（当然，链上数据是透明的，想看的人是能有办法读取出来这些数据的）。
* 抢红包必须先完成JTI认证并获得初始gas空投（否则无法进行链上交互）。
* 限制每个JTI认证的地址对每一批红包只能抢一个，不能重复多次抢。

## 算法

### 创建红包

链下预计算（比如js）。已知两个参数：1. 红包总量total_e = XX * 10^18 (e)；2. 红包总数 total_n =YY (个)

令 left_e = 当前剩余能量值，left_n = 剩余红包个数。每次有人领取红包时（校验：每有效身份可领一次），若 left_n == 1，则红包能量 = 全部剩余能量值；否则，在[1, 2 * left_e / left_n]之间取随机值（均匀分布）作为当前红包 i 的能量值 e ，以wJ形式发送给领取者地址。left_e -= e, left_n -= 1。记录 i => [e, address, block_height] 作为待查询红包领取记录。

24h过期。过期后不能再继续领取。红包创建者可以取回剩余能量（以wJ的形式）。

数据结构：
```
mapping(红包hash => struct {
  creator: address,
  expiry: 过期区块高度（24h）,
  total_e: 红包总能量值,
  total_n: 红包总数,
  left_e: 剩余可领红包能量,
  left_n: 剩余可领红包数量,
  final_e: 最终发出能量值,
  final_n: 最终发出红包数量, //不一定等于total_n，因为过期会导致final_n < total_n
  opened: mapping(i => (e, address, block_height)) //已开红包记录
})
```

函数原型：
```
create(id, quantity, amount)
```

红包id算法：链下生成一个uint256随机数提供即可，合约里校验是否已存在

### 抢红包

首先，该地址需要有JTI。（禁止女巫）

其次，如果该地址已经抢过红包（在 opened 列表里），就不能再抢了。（禁止重放）

取若干不可预知的数据源，比如区块哈希值，加上抢红包者的地址，加上上一个人的last_seed，加上抢红包者传入的一个“随机”幸运数字（lucky_n），算一个hash，uint256 seed = uint256(keccak256(abi.encode(lucky_n, msg.sender, blockhash(block.number - 1), last_seed)))

取 uint256 e = seed % (2 * left_e / left_n)

然后对剩余未抢红包数量求余，算出一个“随机”的index值（这个算法要在合约里运行，不能是链下，防止用户操纵）。根据该index值，从上述数据结构中查找出对应的红包id；将该红包id从index中删除（代表已经被抢走了），减少剩余未抢红包数量，把该红包id对应的amount数量能量的wJ发送给抢红包者的地址。

（注意先减数据，最后再发放wJ，防止重入攻击）

函数原型：
```
open(红包id, 幸运数字lucky_n）
```

### 辅助方法

1. withdraw(红包id) ：过期后，提取未抢红包全部余额。仅限creator有权执行。
2. inspect(红包id, 红包序号n) ：检视红包领取记录。序号范围：[0, final_n)

## 原型代码

```
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract RedPacketPrototype {
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
    }

    mapping(uint256 => RedPacket) public redpackets;

    function create(uint256 id, uint256 quantity, uint256 amount) public {
        require(redpackets[id].created == false, "ERROR: redpacket already created");
        require(quantity <= 500, "ERROR: too many red packets"); //hard-coded 500
        require(amount <= 2000 * 10**18, "ERROR: too much Joule"); //hard-coded 2000
        require(amount >= quantity, "ERROR: too few Joule");

        redpackets[id].created = true;
        redpackets[id].creator = msg.sender;
        redpackets[id].expiry = block.number + (24 hours / 15);
        redpackets[id].total_e = amount;
        redpackets[id].total_n = quantity;
        redpackets[id].left_e = amount;
        redpackets[id].left_n = quantity;
    }

    function open(uint256 id, uint256 lucky_n) public {
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
    }

    function inspect(uint256 id, uint256 n) public view returns (OpenedPacket memory) {
        return redpackets[id].opened[n];
    }

    function withdraw(uint256 id) public {
        require(msg.sender == redpackets[id].creator, "ERROR: only creator can withdraw");
        require(redpackets[id].left_e > 0 && redpackets[id].left_n > 0, "ERROR: nothing left");
        require(block.number >= redpackets[id].expiry, "ERROR: not yet expired");

        // clear
        redpackets[id].left_e = 0;
        redpackets[id].left_n = 0;
        // after clearing, you may check final_e and final_n for references
    }
}
```

## 版本历史

* 2023.10.13 spec-v1.1 evan.j 更新算法和数据结构；红包总能量上限从500 J改为2000 J；原型代码，算法验证
* 2023.9.8 spec-v1.0 evan.j 
