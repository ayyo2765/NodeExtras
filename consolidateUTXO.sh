#!/bin/bash
#Copyright Alex English January 2020
#Adjusted for consolidation by Oink, December 2021.
#Completely rewrote to add support for various coins by ayyo2765@deepfields.io, April 2022 
#This script comes with no warranty whatsoever. Use at your own risk.

#This script looks for unspent transactions below the supplied limit (if none supplied smaller than 2500 coins) and spends them back to the same address. 
#If there are multiple UTXOs on an address, this consolidates them into one output. 
#The standard minimum amount of UTXOs being consolidated is 5, but can be altered using the -m command line option
#The maximum amount of UTXOs being consolidated on a single address is 400.

# Privacy logic not yet reimplemented
#Privacy is preserved because this doesn't comingle any addresses. Furthermore, the option is given to allow for a random delay of 5 to 15 minutes between transaction submissions, so the transactions don't show up as a burst, but are metered over time, likely no more than one per block.

############################################Config_Begin############################################

# Default values
L=2500	#filter out addresses that have a balance above this value
l=1			#filter out utxos that have an amount above this value
m=5			#minimum amount of utxos for address to be considered
t=400		#maximum utxos per consolidation transaction
# P="0,0"	#privacy delay range seconds (min,max)


# Predefined coins
#coin_name,
#miner/transaction fee,
#Inputs vByte,
#Outputs vByte,
#Overhead vByte
coins=(
	"P2WPKH,.0001,68,31,11"			# Generic P2WPKH transaction type coin. Use -f to override defualt fee
	"P2PKH,.0001,148,34,10"			# Generic P2PKH transaction type coin. Use -f to override defualt fee
	"dynamo,.00001,68,31,11"
	"martkist,.0001,148,34,10"
	"sprint,.00001,148,34,10"
)

############################################Config_End############################################

usage(){
	printf "\n"
	printf "Usage: consolidateUTXO.sh [-a -u -p] [-C | -c -f] [options]\n"
	printf " -C \tCoins with predefined vByte size and min fee \tEx. -C dynamo\n"
	printf "\t  dynamo\n"
	printf "\t  martkist\n"
	printf "\t  sprint\n"
	printf "\t  P2WPKH   Generic P2WPKH transaction type coin. Use -f to override default fee\n"
	printf "\t  P2PKH    Generic P2PKH transaction type coin. Use -f to override default fee\n"
	printf " -c \tCustom coin vByte size. \tEx. -c 68,31,11 (inputs,outputs,overhead)\n"
	printf " -f \tFee amount per kB. \tEx. -f .00001\n"
	printf " -a \tRPC address. \tEx. -a 127.0.0.1:6433\n"
	printf " -u \tRPC user. \tEx. -u user\n"
	printf " -p \tRPC password. \tEx. -p 123456\n"
	printf " -l \tThe maximum coin amount for a utxo to be considered for consolidation. Ex. -l 1 (default 1)\n"
	printf " -L \tThe maximum coin amount for a address to be considered for consolidation. Ex. -L 2500 (default 2500)\n"
	printf " -m \tThe minimum number of utxos for address to be considered for consolidation. Ex. -m 5 (default 5)\n"
	printf " -t \tThe maximum UTXOs per consolidation transaction. Limited by OS ARG_MAX. Ex. -t 400 (default 400)\n"
	# printf " -P \tPrivacy mode - Add delay between consolidating addresses to reduce the possibility of correlating ownership of addresses based on time. Ex. -P 5,15 (min,max minutes)\n"
	printf " -R \tRun mode - This will automatically answer yes to all send TX prompts. Thoroughly test before using. Ex. -R "
	printf "\n"
	printf "Examples:\n"
	printf "\n"
	printf "./consolidateUTXO.sh -u user -p password -a 127.0.0.1:8433 -C dynamo -l 2\n"
	printf "  ^ Consolidate up to 400 dynamo UTXOs, containing less than 2 coins, into a single UTXO per transaction\n"
	printf "\n"
	printf "./consolidateUTXO.sh -u user -p password -a 127.0.0.1:4041 -C martkist -t 100 -L 18000\n"
	printf "  ^ Consolidate up to 100 martkist UTXOs, containing less than 1 coin, into a single UTXO per transaction, from each wallet address with less than 18000 coins\n"
	printf "\n"
	printf "./consolidateUTXO.sh -u user -p password -a 127.0.0.1:4041 -c 148,34,10 -f .0001\n"
	printf "  ^ Consolidate up to 400 UTXOs, containing less than 1 coin, into a single UTXO per transaction with a custom vByte size and .0001 fee\n"
	printf "\n"
	exit ${1:-0}
}

############################################No user configurable options below this point############################################

#Dependencies: jq, bc, curl
for dependency in jq bc curl; do 
	if ! command -v $dependency &>/dev/null ; then
		echo "$dependency not found. Please install using your package manager."
		exit 1
	fi
done

############################################Functions############################################

inializeLog(){
	logFile="$(echo $(dirname $(readlink -f "$0"))/consolidateUTXO_$(date +"%Y%m%d_%H%M%S").log)"
	printf "Log will be saved to %s\n" "$logFile"
}

printLogNew(){
	printf "[%s] %s\n" "$(date +"%H:%M:%S")" "$1" | tee -a "$logFile"
}

printLogReturn(){
	printf "[%s] %s\r" "$(date +"%H:%M:%S")" "$1" | tee -a "$logFile"
}


loadCoin(){
	for coin in "${coins[@]}"; do
		if [[ $(cut -d',' -f1 <<< "$coin") == $C ]]; then
			f="$(cut -d',' -f2 <<< "$coin")"
			c="$(cut -d',' -f3-5 <<< "$coin")"
			return
		fi
	done
	echo "No predefined values found for $C"
	echo "If you know the your coin's paramerters, you can try again specifying them with -c and -f"
	echo "You may also open an issue on github to request support for your coin"
	exit 7
}

#Check for required and valid parameter combinations
validateOptions(){
	for option in a u p; do
		if [[ ! ${!option} ]]; then
			echo "Missing option -$option"
			usage 2
		fi
	done
	if [[ ! $C ]] && [[ ! $c ]]; then
		echo "Missing option. Use -C OR -c"
		usage 3
	elif [[ $C ]] && [[ $c ]] ; then
		echo "Incompatable options. Use -C OR -c"
		usage 4
	elif [[ $c ]] && [[ ! $f ]]; then
		echo "Missing option -f"
		usage 5	
	elif [[ $C ]]; then
		loadCoin
	fi
}

# RPC call 
#$1 = method
#$2 = params  
#$3 = boolean to report rpc error - for testing rpc calls expected to fail
curlRPC(){
	responseRPC=""
	responseRPC="$(curl -sS --data-binary '{"jsonrpc":"1.0","id":"curltext","method":"'"$1"'","params":['"$2"']}' -H 'content-type:text/plain;' http://$u:$p@$a/ 2>&1)"
	statusCurl=$?
	if [[ $statusCurl -ne 0 ]]; then
		printLogNew "$responseRPC"
		exit $statusCurl
	fi
	if [[ -z $responseRPC ]]; then
		printLogNew "Blank response from RPC server. Please check your RPC credentials"
		exit 1
	fi
	statusRPC="$(jq -r '.error.code // 0' <<< "$responseRPC")"
	if [[ $statusRPC -ne 0 ]] && ${3:-true}; then
		printLogNew "RPC error code: $statusRPC"
		printLogNew "$(jq -r '"RPC error message: "+.error.message' <<< "$responseRPC")"
		exit $statusRPC
	fi	
}

printSummary(){
	printLogNew "~~~~~~~~~~~~~~~~~Pending transaction summary~~~~~~~~~~~~~~~~"
	printLogNew "input address: $1"
	printLogNew "inputs: $2"
	printLogNew "input amount: $3"
	printLogNew "output address: $4"
	printLogNew "outputs: $5"
	printLogNew "output amount: $6"
	printLogNew "transaction fee: $7"
	printLogNew "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
	
}

userConfirmation() {
	while true; do
		read -p "$(printLogNew "$1")" answer < /dev/tty
		printLogNew "Submitted answer: $answer"
		case $answer in
			[yY]|[yY][eE][sS] )
				return 0
			;;
			[nN]|[nN][oO] ) 
				return 1
			;;
			* ) 
				printLogNew "\"$answer\" is not a valid response. Please answer y[es] or n[o]."
			;;
		esac
	done
}

sendTX(){
	curlRPC sendrawtransaction "$1"
	txSentID="$(jq '.result' <<< "$responseRPC")"
	printLogNew "Sent raw transaction successfully"
	printLogNew "Transaction ID: $txSentID"
}

############################################parameters############################################

# Process options and arguments 
while getopts ":c:C:f:a:u:p:l:L:m:t:P:Rh" opt; do # param reservation
	case $opt in
		c|C|f|a|u|p|l|t|m|L)	# param implemented
			declare $opt="${OPTARG}"
		;;
		R)
			run=true
		;;
		h)
			usage 0
		;;
		\?) 
			echo "Unknown option: -$OPTARG"
			usage 1
		;;
		:) 
			echo "Missing option argument for -$OPTARG"
			usage 1
		;;
		*) 
			echo "Unimplemented option: -$opt"
			usage 1
		;;
	esac
done

############################################Main############################################

# Check parameters
validateOptions

# Create logfile
inializeLog

# Test RPC connection
curlRPC getblockchaininfo

# Test if core uses newer signing method
for signrawtransactionCommand in signrawtransactionwithwallet signrawtransaction; do
	curlRPC $signrawtransactionCommand "" false
	if [[ $statusRPC -eq -1 ]]; then
		printLogNew "Core uses $signrawtransactionCommand"
		break
	fi
done

curlRPC listunspent
listunspent="$responseRPC"
addresses=$(jq -r '[.result[].address]|unique|.[]' <<< "$listunspent")
for address in $addresses; do
	printLogNew "Analyzing UTXOs in address $address"
	utxoFiltered="$(jq -r --arg address "$address" --arg l "$l" '.result[]|select(.address==$address)|select(.amount<($l|tonumber))|.txid+"\t"+(.vout|tostring)+"\t"+(.amount|tostring)' <<< "$listunspent")"
	utxoTotal=$(printf "$utxoFiltered" | grep -c "^")
	utxoRemainder=$utxoTotal
	addressAmount="$(jq -r --arg address "$address" '[.result[]|select(.address==$address and .spendable==true)|.amount] | add' <<< "$listunspent")"
	if (( $(bc -l <<< "$addressAmount>$L") )); then
		printLogNew "This address contains $addressAmount coins, which may include locked inputs, and is over the $L coin limit. Skipping to the next address..."
		utxoFiltered=""
	elif [[ $utxoTotal -lt $m ]]; then 
		printLogNew "Found $utxoTotal UTXOs which is less than the $m UTXO minimum. Skipping to the next address..."
		utxoFiltered=""
	else
		printLogNew "Found $utxoTotal UTXOs to be consolidated"
	fi
	inputCount=1
	inputAmount=0
	inputs='['
	while read utxo; do
		if [[ -z "$utxo" ]]; then
			continue
		fi
		txid="$(cut -f1 <<< $utxo)"
		vout="$(cut -f2 <<< $utxo)"
		amount="$(cut -f3 <<< $utxo)"
		inputAmount=$(bc <<< "$inputAmount+$amount")
		inputs="$inputs{\"txid\":\"$txid\",\"vout\":$vout},"
		printLogReturn "Adding input $txid. Consolidation TX now contains $inputCount inputs totaling $inputAmount coins"
		if [[ $inputCount -eq $t ]] || [[ $inputCount -eq $utxoTotal ]]; then 
			printf "\33[2K\r"
			if [[ $inputCount -eq 1 ]]; then 
				printLogNew "Consolidation TX only contains 1 input. Skipping to the next address..."
			else
				printLogNew "Consolidation TX contains $inputCount inputs totaling $inputAmount coins"
				inputs="${inputs%,}]"
				txFee="$(bc <<< "scale=8;(($inputCount*$(cut -d',' -f1 <<< $c))+$(cut -d',' -f2 <<< $c)+$(cut -d',' -f3 <<< $c))*($f/1000)")"
				outputAmount="$(bc <<< "$inputAmount-$txFee")"
				outputs="{\"$address\":$outputAmount}"
				printLogNew "Calculated TX fee of $txFee. The TX output amount will be $outputAmount coins"

				curlRPC createrawtransaction "$inputs,$outputs"
				txHEX="$(jq '.result' <<< "$responseRPC")"
				printLogNew "Created raw transaction successfully"

				curlRPC $signrawtransactionCommand "$txHEX"
				txSignedHEX="$(jq '.result.hex' <<< "$responseRPC")"
				printLogNew "Signed raw transaction successfully"

				printSummary $address $inputCount $inputAmount $address 1 $outputAmount $txFee
				if ${run:-false}; then
					printLogNew "Run paramerter is set. Automatically submitting the pending transaction"
					sendTX "$txSignedHEX"
				elif userConfirmation "Do you wish to send this TX? (y/n) "; then 
					sendTX "$txSignedHEX"
				else
					if userConfirmation "Do you wish to skip to the next input address? (y/n) "; then
						break
					fi
				fi
				utxoRemainder=$((utxoRemainder-inputCount))
				if [[ $utxoRemainder -gt 1 ]]; then
					printLogNew "Building next TX. $utxoRemainder inputs still to be consolidated"
				fi
			fi
			inputCount=1
			inputAmount=0
			inputs='['
		fi
		((inputCount++))
	done <<< "$utxoFiltered"
	printLogNew "No more UTXOs to consolidate in this address. Checking next address in wallet"
done
printLogNew "No more addresses found in wallet. Consolidation completed"

