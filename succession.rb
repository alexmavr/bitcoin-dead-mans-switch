require 'optparse'
require_relative 'ops'

options = {
  key_file: "#{Dir.pwd}/succession.key",
  p2sh_state_file: "#{Dir.pwd}/p2sh.state",
  successor: false
}

subcommands = {
  'keygen' => OptionParser.new do |opts|
    opts.on("-k", "--key-file [FILE]", String, "The path to the file holding the base58-encoded private key") do |v|
      options[:key_file] = v
    end
  end,
  'set-successor' => OptionParser.new do |opts|
    opts.on("-k", "--key-file [FILE]",  String,"The path to the file holding the base58-encoded private key") do |v|
      options[:key_file] = v
    end
    opts.on("-p", "--pubkey [PKEY]", String, "The public key of the wallet successor") do |v|
      options[:pubkey] = v
    end
    opts.on("-t", "--locktime [LOCKT]", String, "The UNIX epoch time or block height when funds will spendable by the successor") do |v|
      options[:time] = v
    end
  end,
  'balance' => OptionParser.new do |opts|
    opts.on("-k", "--key-file [FILE]", String, "The path to the file holding the base58-encoded private key") do |v|
      options[:key_file] = v
    end
    opts.on("-k", "--p2sh-state-file [FILE]", String, "The path to the file holding the base58-encoded private key") do |v|
      options[:p2sh-state-file] = v
    end
  end,
  'send' => OptionParser.new do |opts|
    opts.on("-k", "--key-file [FILE]", String, "The path to the file holding the base64-encoded private key") do |v|
      options[:key_file] = v
    end
    opts.on("-t", "--to [TO]", String, "The address to send funds to") do |v|
      options[:to] = v
    end
    opts.on("-c", "--amount [AMOUNT]", String, "The amount of Bitcoin to send") do |v|
      options[:amount] = v
    end
    opts.on("-s", "--successor", String, "Attempt to spend the redeem script as the successor") do |v|
      options[:successor] = true
    end
  end,
}

subcommand = ARGV.shift
raise StandardError, 'Available commands: keygen, set-successor, balance, send' unless subcommands.include? subcommand
subcommands[subcommand].order!

case subcommand
when 'keygen'
  keygen(options[:key_file])
when 'set-successor'
  set_successor(options[:key_file], options[:pubkey], options[:time])
when 'balance'
  balance(options[:key_file], options[:p2sh_state_file])
when 'send'
  send_btc(options[:key_file], options[:to], options[:amount], options[:p2sh_state_file], options[:successor])
end