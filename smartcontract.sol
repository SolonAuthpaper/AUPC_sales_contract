/*
 * Copyright 2019 Authpaper Team
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
pragma solidity ^0.5.1;
import "github.com/oraclize/ethereum-api/oraclizeAPI.sol";

contract Adminstrator {
  address public admin;
  address payable public owner;

  modifier onlyAdmin() { 
        require(msg.sender == admin || msg.sender == owner,"Not authorized"); 
        _;
  } 

  constructor() public {
    admin = msg.sender;
	owner = msg.sender;
  }

  function transferAdmin(address newAdmin) public onlyAdmin {
    admin = newAdmin; 
  }
}
contract DateTime {
	function toTimestamp(uint16 year, uint8 month, uint8 day) public constant returns (uint timestamp);
}
contract TokenERC20 {
	function transferFrom(address _from, address _to, uint256 _value) public returns (bool success);
	function burnFrom(address _from, uint256 _value) public returns (bool success);
	mapping (address => mapping (address => uint256)) public allowance;
}
contract FiftyContract is Adminstrator,usingOraclize {
	/**
	When someone make a payment, receive get money, if it is after 16 Aug 2019 00:00 anywhere in the world, emit shouldBurn event and return the money
	And then call getLevels?eth=... to get the levels in order to calculate the discount and distribute the AUPC
	And then call GetAddresses?eth=... up to three times to send out the promotional AUPC and eth
	Also get a number about how much AUPC and ETH is sold by the downline of the accounts
	To delete things in mapping, delete user[someAddress];
	*/
	
	//Date and time related
	address public dateTimeAddr = 0x1a6184CD4C5Bea62B0116de7962EE7315B7bcBce;
	DateTime public dateTime = DateTime(dateTimeAddr);
	uint public oneDayTime = 86400;
	uint public deadline = dateTime.toTimestamp(2019,8,16) + 12*3600; //GMT - 12, Make sure anywhere in the world is 16 Aug 2019
	//Web query related
	string public addrWebsite="https://authpaper.io/getAddresses?eth=";
	string public levelWebsite="https://authpaper.io/getLevels?eth=";
	enum queryType{
		checkLevels;
		findParents;
	}
	struct rewardNode{
		address baseAddress;
		uint purchasedETH;
		uint receivedAUPC;
		uint levels;
		queryType qtype;
	}
	struct tempLevel{
		uint level;
		uint timeStamp;
	}
	struct tempAddress{
		address addr;
		uint timeStamp;
	}
	mapping (bytes32 => rewardNode) public oraclizeCallbacks;
	mapping (address => tempLevel) public savedLevels;
	mapping (address => tempAddress) public savedParents;
	
	//Purchase and distribution related
	address public tokenAddr = 0x500Df47E1dF0ef06039218dCF0960253D89D6658;
	TokenERC20 public AUPC = TokenERC20(tokenAddr);
	uint firstLevelAUPC=10;
	uint firstLevelETH=5;
	uint secondLevelAUPC=6;
	uint secondLevelETH=3;
	uint thirdLevelAUPC=4;
	uint thirdLevelETH=2;
	uint firstLevelDiscount=5;
	uint secondLevelDiscount=3;
	uint thirdLevelDiscount=2;
	uint maxDiscount=15;
	uint public basePrice = 1 finney;
	uint public minPurchase = 100 finney;
	event distributeETH(address indexed _to, address _from, uint _amount);
	event distributeAUPC(address indexed _to, address _from, uint _amount);
	event shouldBurn(address _from, uint _amount);
	
	//Statistic issue
	uint256 public receivedAmount=0;
	uint256 public sentAmount=0;
	uint256 public sentAUPC=0;
	bool public paused=false;
	event Paused(address account);
	event Unpaused(address account);
	event makeQuery(address indexed account, string msg);
	event MasterWithdraw(uint amount);
	mapping (address => uint) public gainedETH;
	mapping (address => uint) public gainedAUPC;
	mapping (address => uint) public payedAUPC;
	mapping (address => uint) public payedETH;
	mapping (address => uint) public payedETHSettled;
	mapping (address => uint) public sentAwayETH;
	mapping (address => uint) public sentAwayAUPC;
	
	//Setting the variables
	function setWebsite(string memory addr, string memory level) public onlyAdmin{
		require(paused,"The contract is still running");
		addrWebsite = addr;
		levelWebsite = level;
	}
	function setPrice(uint newPrice, uint newMinPurchase) public onlyAdmin{
		require(paused,"The contract is still running");
		require(newPrice > 0, "new price must be positive");
		require(newMinPurchase > 0, "new minipurchase must be positive");
		require(newMinPurchase > 10*newPrice, "new minipurchase must be larger than new price");
		basePrice = newPrice * (10 ** uint256(15)); //In finney
		minPurchase = newMinPurchase * (10 ** uint256(15)); //In finney
	}
	function pause(bool isPause) public onlyAdmin{
		paused = isPause;
		if(isPause) emit Paused(msg.sender);
		else emit Unpaused(msg.sender);
	}
	function withdraw(uint amount) public onlyAdmin returns(bool) {
        require(amount < address(this).balance);
        owner.transfer(amount);
		emit MasterWithdraw(amount);
        return true;
    }	
	
	function() external payable { 
		require(msg.sender != 0x0); //Cannot buy AUPC by empty address
		if(msg.sender == owner){
			//The admin can pay ETH to contract, not buying AUPC
			return;
		}
		require(!paused,"The contract is paused");
		require(address(this).balance + msg.value > address(this).balance); //prevent overflow
		requre(msg.value > minPurchase, "Please purchase at least the minimum amount");
		if(now > deadline){
			paused = true;
			//Token sales is over, it is time to burn the remaining tokens
			emit shouldBurn(owner,AUPC.allowance(address(this)));
			//Send back the money
			if(msg.value < address(this).balance)
				msg.sender.transfer(msg.value);
			//Problem: How to make sure all pending ETH and AUPC are sent out before burning all AUPC?
			//AUPC.burnFrom(owner,AUPC.allowance(address(this)));
		}
		//The discount info is queried in the previous one day.
		if(savedLevels[msg.sender].timeStamp >0 
			&& savedLevels[msg.sender].timeStamp + oneDayTime >now){
			require(purchaseAUPC(msg.sender, msg.value,savedLevels[msg.sender].level));
			receivedAmount += msg.value;
			payedETH[msg.sender] += msg.value;
			return;
		}
		//make query for levels
		//Remember, each query may burn around 0.01 USD from the contract !!
		string memory queryStr = strConcating(levelWebsite,addressToString(msg.sender));
		emit makeQuery(msg.sender,"Oraclize level query sent");
		bytes32 queryId=oraclize_query("URL", queryStr, 600000);
        oraclizeCallbacks[queryId] = rewardNode(msg.sender,msg.value,0,0,queryType.checkLevels);
		receivedAmount += msg.value;
		payedETH[msg.sender] += msg.value;
	}
	function __callback(bytes32 myid, string memory result) public {
        if (msg.sender != oraclize_cbAddress()) revert();
        rewardNode memory o = oraclizeCallbacks[myid];
		if(o.qtype == queryType.checkLevels){
			//Checking the number of levels for an address, notice that the AUPC is not sent out yet
			uint levels = stringToUint(result);
			savedLevels[o.baseAddress] = tempLevel(levels, now);
			require(purchaseAUPC(o.baseAddress,o.purchasedETH,levels));
		}
		if(o.type == queryType.findParents){
			address parentAddr = parseAddrFromStr(result);
			savedParents[o.baseAddress] = tempAddress(parentAddr, now);
			require(sendUpline(o.baseAddress,o.purchasedETH,o.purchasedAUPC,parentAddr,o.levels));
		}
		delete oraclizeCallbacks[myid];
    }
	function purchaseAUPC(address buyer, uint amount, uint levels) internal returns (bool){
		require(buyer != 0x0); //Cannot buy AUPC by empty address
		require(buyer != owner); //Cannot buy AUPC by empty address
		require(payedETH[buyer] >= amount + payedETHSettled[buyer], "Too much ETH to settle"); //Make sure the buyer has really pay that money.
		require(amount > minPurchase, "Not enough ETH to send out AUPC");
		uint discount=0;
		if(levels >0){
			if(levels >0) discount += firstLevelDiscount;
			if(levels >1) discount += secondLevelDiscount;
			if(levels >2) discount += thirdLevelDiscount;
			if(levels >3) discount += (levels -3);
		}
		if(discount > maxDiscount) discount = maxDiscount; //Make sure the discount is not too large
		require((basePrice * (100 - discount)) > basePrice);
		uint currentPrice = (basePrice * (100 - discount)) / 100;
		require(currentPrice < basePrice); //There should be discount
		require(currentPrice > 0, "Current price goes to zero"); 
		uint amountAUPC = amount / currentPrice;
		require(amountAUPC > 0, "No AUPC is purchased");
		require((amount - (amountAUPC * currentPrice)) >=0); //There should be a round down issue, if the division has remainder
		uint oldBalance = AUPC.allowance(address(this));
		require(AUPC.transferFrom(owner, buyer, amountAUPC)); //Pay out AUPC
		//We have settled this amount of ETH to AUPC and sent out
		payedETHSettled[buyer] += amount;
		payedAUPC[buyer] += amountAUPC;
		sentAUPC += amountAUPC;
		emit distributeAUPC(address indexed buyer, address owner, uint amountAUPC);
		assert(oldBalance == (AUPC.allowance(address(this)) + amountAUPC)); //It should never fail
		
		if(savedParents[buyer].timeStamp >0 
			&& savedParents[buyer].timeStamp + oneDayTime >now){
			require(sendUpline(buyer,amount,amountAUPC, savedParents[buyer].addr,1));
		}else{
			//make query for parent
			string memory queryStr = strConcating(addrWebsite,addressToString(buyer));
			emit makeQuery(msg.sender,"Check parent query sent");
			bytes32 queryId=oraclize_query("URL", queryStr, 600000);
			oraclizeCallbacks[queryId] = rewardNode(buyer,amount,amountAUPC,1,queryType.findParents);
		}
		return true;
	}
	function sendUpline(address buyer,uint amount,uint amountAUPC, address parent, uint levels) internal returns (bool){
		require(buyer != 0x0); //empty address cannot be a referrer or buyer
		require(buyer != owner); //Cannot buy AUPC by empty address
		require(parent != 0x0); //Cannot bt referral by empty address
		if(parent == owner) return true; //The referrer is owner means there is no referral and it is the top already
		require(level <4); //Maximum distribute three levels
		uint aupcRate = amountAUPC;
		uint ethRate = amount;
		if(levels >0){
			if(levels ==1){
				aupcRate = aupcRate * firstLevelAUPC;
				ethRate = ethRate * firstLevelETH;
			} 
			if(levels ==2){
				aupcRate = aupcRate * secondLevelAUPC;
				ethRate = ethRate * secondLevelETH;
			}
			if(levels ==3){
				aupcRate = aupcRate * thirdLevelAUPC;
				ethRate = ethRate * thirdLevelETH;
			}
			if(levels >3) return true;			
		}else return true;
		require(aupcRate > amountAUPC);
		require(ethRate > amount);
		require(aupcRate <= 10*amountAUPC); //We send out max 10%
		require(ethRate <= 10*amount);
		aupcRate = aupcRate / 100;
		ethRate = ethRate / 100;
		
		require(aupcRate > 0, "No AUPC will send out");
		require(ethRate > 0, "No ETH marketing award is sending out");
		require(ethRate < address(this).balance, "No enough ETH for marketing award");
		uint oldBalance = AUPC.allowance(address(this));
		uint oldETHBalance = address(this).balance;
		require(AUPC.transferFrom(owner, parent, aupcRate)); //Pay out AUPC
		parent.transfer(ethRate); //Pay out ETH
		//We have settled this amount of ETH to AUPC and sent out
		gainedETH[parent] += ethRate;
		gainedAUPC[parent] += aupcRate;
		sentAwayETH[buyer] += ethRate;
		sentAwayAUPC[buyer] += aupcRate;
		sentAUPC += aupcRate;
		sentAmount += ethRate;
		emit distributeAUPC(address indexed parent, address owner, uint aupcRate);
		emit distributeETH(address indexed parent, address owner, uint ethRate);
		assert(oldBalance == (AUPC.allowance(address(this)) + aupcRate)); //It should never fail
		assert(oldETHBalance == (address(this).balance; + ethRate)); //It should never fail
		
		if(savedParents[parent].timeStamp >0 
			&& savedParents[parent].timeStamp + oneDayTime >now){
			require(sendUpline(buyer,amount,amountAUPC, savedParents[parent].addr,levels+1));
		}else{
			//make query for parent
			string memory queryStr = strConcating(addrWebsite,addressToString(parent));
			emit makeQuery(msg.sender,"Check parent query sent");
			bytes32 queryId=oraclize_query("URL", queryStr, 600000);
			oraclizeCallbacks[queryId] = rewardNode(buyer,amount,amountAUPC,levels+1,queryType.findParents);
		}
		return true;
	}
	function stringToUint(string s) internal pure returns (uint){
		byte memory b = bytes(s);
		uint result = 0;
		for(uint i=0;i < b.length; i++){
			if(b[i] >=48 && b[i]<=57) result = (result * 10) + (uint(b[i]) - 48);
		}
		return result;
	}
    function strConcating(string memory _a, string memory _b) internal pure returns (string memory){
        bytes memory _ba = bytes(_a);
        bytes memory _bb = bytes(_b);
        string memory ab = new string(_ba.length + _bb.length);
        bytes memory bab = bytes(ab);
        uint k = 0;
        for (uint i = 0; i < _ba.length; i++) bab[k++] = _ba[i];
        for (uint i = 0; i < _bb.length; i++) bab[k++] = _bb[i];
        return string(bab);
    }
    function addressToString(address _addr) public pure returns(string memory) {
        bytes32 value = bytes32(uint256(_addr));
        bytes memory alphabet = "0123456789abcdef";    
        bytes memory str = new bytes(42);
        str[0] = '0';
        str[1] = 'x';
        for (uint i = 0; i < 20; i++) {
            str[2+i*2] = alphabet[uint8(value[i + 12] >> 4)];
            str[3+i*2] = alphabet[uint8(value[i + 12] & 0x0f)];
        }
        return string(str);
    }
    function parseAddrFromStr(string memory _a) internal pure returns (address payable){
         bytes memory tmp = bytes(_a);
         uint160 iaddr = 0;
         uint160 b1;
         uint160 b2;
         for (uint i=2; i<2+2*20; i+=2){
             iaddr *= 256;
             b1 = uint8(tmp[i]);
             b2 = uint8(tmp[i+1]);
             if ((b1 >= 97)&&(b1 <= 102)) b1 -= 87;
             else if ((b1 >= 48)&&(b1 <= 57)) b1 -= 48;
             if ((b2 >= 97)&&(b2 <= 102)) b2 -= 87;
             else if ((b2 >= 48)&&(b2 <= 57)) b2 -= 48;
             iaddr += (b1*16+b2);
         }
         return address(iaddr);
    }
}