require 'bitcoin'
require 'net/http'
require 'json'

def keygen(key_file)
  key = Bitcoin::Key.generate()
  open(key_file, 'w') do |f|
    f.puts key.to_base58()
  end
  puts "Stored generated key in #{key_file} with public key #{key.pub} for address #{key.addr}"
end

def set_successor(key_file, pubkey, locktime)
  file_data = []
  open(key_file, 'r') do |f|
    file_data = f.readlines.map(&:chomp)
  end

  raise StandardError, "Key file is empty" if file_data.empty?

  key = Bitcoin::Key.from_base58(file_data[0])
  puts pubkey
  puts locktime

  open(key_file, 'w') do |f|
    f.truncate(0)
    f.puts(key.to_base58())
    f.puts(pubkey)
    f.puts(locktime)
  end
end

def get_redeem_script(pubkey, successor_pubkey, locktime)
  script = Bitcoin::Script.new('')
  script.append_opcode(Bitcoin::Script::OP_IF)
  script.append_pushdata([pubkey].pack('H*'))
  script.append_opcode(Bitcoin::Script::OP_CHECKSIG)
  script.append_opcode(Bitcoin::Script::OP_ELSE)
  puts locktime
  script.append_pushdata( [locktime.to_i.to_s(16)].pack('H*'))
  script.append_opcode(178) # OP_CHECKSEQUENCEVERIFY
  script.append_opcode(Bitcoin::Script::OP_DROP)
  script.append_pushdata([successor_pubkey].pack('H*'))
  script.append_opcode(Bitcoin::Script::OP_CHECKSIG)
  script.append_opcode(Bitcoin::Script::OP_ENDIF)
  script
end

def get_utxos(address)
  net = Net::HTTP.new('blockchain.info', 443)
  net.use_ssl = true
  #net.get_response("/unspent?active=#{address}")
  net.request_get("/unspent?active=#{address}") do |resp|
    return [] if resp.body.include? 'No free outputs to spend'
    return JSON.parse(resp.body)['unspent_outputs']
  end
end

def get_tx(tx_hash)
  net = Net::HTTP.new('blockchain.info', 443)
  net.use_ssl = true
  #net.get_response("/unspent?active=#{address}")
  net.request_get("/tx/#{tx_hash}?format=hex") do |resp|
    raise StandardError, 'Transaction not confirmed on-chain yet' if resp.body.include? 'Transaction not found'
    return resp.body
  end
end

def balance(key_file, p2sh_state_file)
  file_data = []
  open(key_file, 'r') do |f|
    file_data = f.readlines.map(&:chomp)
  end
  key = Bitcoin::Key.from_base58(file_data[0])
  key_address = key.addr

  total_balance = 0.0
  begin
    open(p2sh_state_file, 'r') do |f|
      file_data = f.readlines.map(&:chomp)
    end
    p2sh_address = file_data[0]
    balance_from_p2sh = balance_from_utxos(get_utxos(p2sh_address)) * 1.0 /(10**8)
    puts "Balance from p2sh for address #{p2sh_address}: #{balance_from_p2sh}"
    total_balance += balance_from_p2sh
  rescue Errno::ENOENT
  end

  balance_from_key = balance_from_utxos(get_utxos(key_address)) * 1.0 /(10**8)
  total_balance += balance_from_key
  puts "Balance from p2pkh for address #{key_address}: #{balance_from_key}"

  puts "Total balance: #{total_balance}"
end

def balance_from_utxos(utxos)
  balance = 0
  utxos.each do |utxo|
    balance += utxo['value']
  end
  balance
end

def send_btc(key_file, to, amount, p2sh_state_file, is_successor)
  file_data = []
  open(key_file, 'r') do |f|
    file_data = f.readlines.map(&:chomp)
  end

  raise StandardError, "Key file is empty" if file_data.empty?
  raise StandardError, "A successor has not been set yet" unless file_data.length.equal?(3)

  key = Bitcoin::Key.from_base58(file_data[0])
  #puts "Pubkey of current key: #{key.pub}"

  successor_pubkey = file_data[1] # TODO: validate
  locktime = file_data[2] # TODO: validate

  open(p2sh_state_file, 'r') do |f|
    file_data = f.readlines.map(&:chomp)
  end
  p2sh_address = file_data[0]
  p2sh_raw_redeem_script = file_data[1]
  p2sh_script = Bitcoin::Script.new([p2sh_raw_redeem_script].pack('H*'))
  puts "Redeem script: #{p2sh_script.to_string}"

  tx = Bitcoin::Protocol::Tx.new

  # Add inputs for both key and script address
  key_utxos = get_utxos(key.addr)
  script_utxos = get_utxos(p2sh_address)
  (key_utxos + script_utxos).each do |utxo|
    tx.add_in(Bitcoin::Protocol::TxIn.new([utxo['tx_hash']].pack('H*'), utxo['tx_output_n']))
  end

  # Add normal send output
  b = balance_from_utxos(key_utxos+script_utxos)
  flat_amount = (amount.to_f * 10**8).floor
  tx.add_out(Bitcoin::Protocol::TxOut.value_to_address(flat_amount, to))

  # Send change and timelock
  change = b - flat_amount - 10000 # Flat fee of 10k satoshis TODO: better fee calculation
  raise StandardError, "Balance is only #{b * 1.0/10**8}, can't send that much" if change.negative?
  s = get_redeem_script(key.pub, successor_pubkey, locktime)
  puts "Output Script: #{s.to_string}"
  p2sh_addr = Bitcoin.hash160_to_p2sh_address(Bitcoin.hash160(s.to_binary.unpack1('H*')))
  puts "P2SH address: #{p2sh_addr}"

  # Write down the new p2sh address and redeem script
  open(p2sh_state_file, 'w') do |f|
    f.puts p2sh_addr
    f.puts s.to_binary.unpack1('H*')
  end

  txout = Bitcoin::Protocol::TxOut.value_to_address(change, p2sh_addr)
  txout.redeem_script = s
  tx.add_out(txout)

  # Sign inputs
  sighash_type = Bitcoin::Script::SIGHASH_TYPE[:all]
  tx.inputs.each_with_index do |input, i|
    prev_tx_hash = input.prev_out_hash.reverse.unpack1('H*')
    prev_tx = Bitcoin::Protocol::Tx.new([get_tx(prev_tx_hash)].pack('H*'))
    prev_out = prev_tx.out[input.prev_out_index]

    # Check if this is one of the p2sh inputs
    if Bitcoin::Script.new(prev_out.pk_script).is_p2sh?
      sig = tx.signature_hash_for_input(i, [p2sh_raw_redeem_script].pack('H*'))
      signed = key.sign(sig)

      puts "Signing input #{i} as a p2sh input"
      # TODO: determine if this is the primary or secondary key
      signature = Bitcoin::Script.pack_pushdata(signed + [sighash_type].pack('C'))
      #puts "Signature: #{signature.unpack1('H*')}"

      op_choose_branch = if is_successor
                           [Bitcoin::Script::OP_FALSE].pack('C*')
                         else
                           [Bitcoin::Script::OP_TRUE].pack('C*')
                         end

      # The redeem script is ~79 bytes so we need an OP_PUSHDATA
      #puts "REDEEM HEX: #{p2sh_raw_redeem_script}"
      p2sh_bin = Bitcoin::Script.pack_pushdata([p2sh_raw_redeem_script].pack('H*'))

      tx.inputs[i].script_sig = signature + op_choose_branch + p2sh_bin

      # DEBUG
      #scriptsig_test = Bitcoin::Script.new(tx.inputs[i].script_sig + prev_out.pk_script)
      #puts scriptsig_test.to_string
      #puts scriptsig_test.run
      #puts scriptsig_test.debug
      #raise StandardError, 'Failed to confirm signing of redeem script with true' unless scriptsig_test.run
    else
      sig = tx.signature_hash_for_input(i, prev_out.pk_script)
      signed = key.sign(sig)

      puts "Signing input #{i} as a pubkey input"
      tx.inputs[i].script_sig = Bitcoin::Script.to_signature_pubkey_script(signed, [key.pub].pack('H*'), sighash_type)
    end

    # Verify input
    raise StandardError, "unable to verify input #{i}" unless tx.verify_input_signature(i, prev_tx)
  end

  puts "Resulting transaction:"
  pp tx.to_json

  puts ""
  puts "P2SH address: #{p2sh_addr}"
  puts ""

  puts "Transaction hex:"
  puts tx.to_payload.unpack1('H*')

end
