# Dead Man's Switch Bitcoin Wallet

This CLI Bitcoin wallet written in Ruby uses timelocked UTXOs to act as a dead
man's switch. After configuring a time period (nSequence), the owner needs to
periodically use the wallet to withdraw funds. If the owner does not use the
wallet within the configured time period, the funds become spendable by the
successor.

This is performed by managing a p2sh address mapping to the following Bitcoin Script:
```
OP_If
	<Owner’s pubkey> OP_CheckSig
OP_Else
	<TTL> OP_CheckSequenceVerify
	OP_Drop
	<Successor’s pubkey> OP_CheckSig
OP_EndIf
```
Donations accepted at 19LfwY1x5j3mNeBZ8MamfMAuxbsMbpoFEe

## Installation
bundle install

## Owner Usage

### Generate owner key
The following operation will create a `succession.key` file in your local
directory with the contents of your private key
``
./succession keygen
``
### Configure successor 
The following operation will configure a successor to your funds. Future
transactions sent from this wallet will include a "change" output to a p2sh
address derived by your succession config.
```
./succession -p <successor_public_key> -t <nSequence>
```
### Get current balance
Retrieves the balance mapping to the sum of your key's p2pkh address, and of the
configured p2sh address.
```
./succession balance
```
### Construct send transaction
This operation will construct and sign a Bitcoin transaction and output it in
JSON and hex to stdout. You should upload the constructed transaction to a
[Bitcoin node](https://txid.io/wallet/#broadcast).

To spend funds as an owner, refreshing the timelock period:
```
./succession send -t <btc_address> -c <bitcoin_amount>
```
After the transaction is generated, a `p2sh.state` file will be created on your
working directory. This file contains the p2sh redeem script and should be sent
to the successor.

### Successor usage

The successor should create a new wallet via `./succession keygen` and configure
their own successor via `./succession -p <next_successor_public_key> -t
<nSequence>`. Then, they should paste the `p2sh.state` file provided to them by
the owner into the working dir.

After the timelock period has expired, the successor can use the following
command to create a bitcoin transaction which spends the funds using the
successor key:
```
./succession send -t <btc_address> -c <bitcoin_amount> -s
```
