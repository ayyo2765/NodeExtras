#!/bin/bash
#Copyright Alex English January 2020
#Adjusted for consolidation by Oink, December 2021.
#Reworking to add support for various coins by ayyo2765 April 2022
#This script comes with no warranty whatsoever. Use at your own risk.

#This script looks for unspent transactions below the supplied limit (if none supplied smaller than 2500) and spends them back to the same address. If there are multiple UTXOs on an address, this consolidates them into one output. Privacy is preserved because this 
#doesn't comingle any addresses. Furthermore, the option is given to allow for a random delay of 5 to 15 minutes between transaction submissions, so the transactions don't show up as a burst, but are metered over time, likely no more than one per block.
#The standard minimum amount of UTXOs being consolidated is 5, but can be altered using the -np command line option
#The maximum amount of UTXOs being consolidated on a single address is 400.

#Usage: ./consolidator.sh bitcoin-cli [-max || --maximum-size] [-np || --noprivacy]
#maxvalue is the upper limit of the UTXO sizes to consolidate. If not provided a standard value of 2500 is used.
#Unless -np||--no-privacy a delay is used between addresses to increase privacy. If false is passed, all actions will be performed without delay, finishing quickly, but also creating the possibility of correlating the addresses based on time.

if ! command -v "$(echo $1 | cut -d' ' -f1)" &>/dev/null ; then
	echo "$1 is not a valid cli. Please specify as bicoin-cli or /usr/bin/bitcoin-cli"
	exit 1
fi

#Dependencies: jq (command-line json parser/editor), bc (command-line calculator)
if ! command -v jq &>/dev/null ; then
	echo "jq not found. please install using your package manager."
	exit 1
fi

if ! command -v bc &>/dev/null ; then
	echo "bc not found. please install using your package manager."
	exit 1
fi

#set defaults
SENTTRANSACTION=""
USEDELAY=true
LIMIT=2500
MIN=5
DEFAULT_FEE_KB=".00001"
INPUTS_SIZE=68
OUTPUTS_SIZE=31
OVERHEAD_SIZE=11
DB=$(mktemp -d)
CLI="$1"

# check if core uses newer signing method
if [[ $(signrawtransactionwithwallet 2&>1 /dev/null || echo $?) -eq 89 ]]; then
	LEGACY=true
else
	LEGACY=false
fi

#process command line parameters
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  key="$2"

  case $key in
	-max|--maximum-size)
	  LIMIT=$3
	  shift # past argument
	  shift # past value
	  ;;
	-np|--no-privacy)
	  USEDELAY=""
	  shift # past argument
	  ;;
   -mu|--minimum-utxos)
	  MIN=$3
	  shift # past argument
	  shift # past value
	  ;;
	-h|--help)
	  printf "\nUsage:\n\nconsolidator.sh bitcoin-cli [options]\n\n"
	  printf "Options:\n\n"
	  printf "\t-max #\t--maximum-size # :\tThe maximum UTXO size to include in the consolidation. (default 2500)\n"
	  printf "\t-np\t--no-privacy :\t\tDo not delay between consolidating multiple addresses, finishing quickly, but also creating the possibility of correlating the addresses based on time.\n"
	  printf "\t-mu #\t--minimum-utxos # :\tThe minimum number of UTXOs to include in the consolidation. (default 5)\n"
	  printf "\nExamples:\n\n"
	  printf "consolidator.sh bitcoin-cli -max 1000\t\tConsolidate all UTXOs containing less than 1000 into a single UTXO, using the standard privacy enhancing delay\n"
	  printf "consolidator.sh bitcoin-cli -np\t\t\tConsolidate all UTXOs containing less than 2500 into a single UTXO, fast, with no regards to privacy accross addresses\n"
	  printf "consolidator.sh bitcoin-cli -np -max 25 -mu 10\t\tConsolidate all UTXOs (at least 10)  containing less than 25 into a single UTXO, fast, with no regards to privacy accross addresses\n"
	  printf "\n"
	  exit 0
	  ;;
	*)    # unknown option
	  POSITIONAL+=("$1") # save it in an array for later
	  shift # past argument
	  ;;
  esac
done

#listunspent, filter for limit amout
$CLI listunspent 1 | jq -cr --arg LIMIT "$LIMIT" ".[]|select(.amount<${LIMIT})|.address+\"\t\"+(.confirmations|tostring)+\"\t\"+.txid+\"\t\"+(.vout|tostring)+\"\t\"+(.amount|tostring)" | \
	while read L; do
		#for each, look up the block - if it is minted the utxo is staked
		CONF=$(awk '{print $2}' <<< "$L")
		#append txid and vout to file named for the address in $DB/
		ADDR=$(awk '{print $1}' <<<"$L")
		printf "$L\n" >> "$DB/$ADDR"
	done
#format of lines in address files is address, confirmations, txid, vout
for F in $(ls -1A $DB); do
	#random delay from 5 minutes to 15 minutes
	ADDR="$F"
	INPUTS='['
	AMOUNT=0
		UTXOS=$(sed -n "$=" "$DB/$F")
		COUNTER=0
		if [ $UTXOS -ge $MIN ]; then
			if [ "$USEDELAY" ] && [ "$SENTTRANSACTION" ]; then
				DELAY=$((300+RANDOM%600))
				date
				echo "Using delay for privacy - sleeping $DELAY seconds"
				sleep $DELAY
				printf "\n"
			fi
		while read L; do
			#build transaction inputs
			TXID=$(awk '{print $3}' <<<"$L")
			VOUT=$(awk '{print $4}' <<<"$L")
			INPUTS="$INPUTS{\"txid\":\"$TXID\",\"vout\":$VOUT},"

			INAMOUNT=$(awk '{print $5}' <<<"$L")
			AMOUNT=$(bc<<<"$AMOUNT+$INAMOUNT")
			((COUNTER++))
			if [[ "$COUNTER" == '400' ]]; then
				break
			fi
		done < "$DB/$F"
		INPUTS="${INPUTS%,}]"

		# calculate fee
		TXFEE="$(echo "scale=8;(($COUNTER*$INPUTS_SIZE)+$OUTPUTS_SIZE+$OVERHEAD_SIZE)*($DEFAULT_FEE_KB/1000)" | bc)" # P2WPKH
		OUTAMOUNT=$(bc<<<"$AMOUNT-$TXFEE")
		OUTPUTS="{\"$ADDR\":$OUTAMOUNT}"
		echo "Consolidating and moving $OUTAMOUNT on address $ADDR into a single UTXO"
		echo "$COUNTER of $UTXOS UTXOs are being processed."
		#createrawtransaction
		TXHEX="$($CLI createrawtransaction "$INPUTS" "$OUTPUTS")"
		echo "TXHEX: $TXHEX"
		#signrawtransaction
		if $LEGACY; then 
			SIGNEDTXHEX="$($CLI signrawtransaction "$TXHEX" | jq -r '.hex')"
		else
			SIGNEDTXHEX="$($CLI signrawtransactionwithwallet "$TXHEX" | jq -r '.hex')"
		fi
		#sendrawtransaction
		SENTTXID="$($CLI sendrawtransaction "$SIGNEDTXHEX")"
		echo "TXID: $SENTTXID"
		printf "\n"
		SENTTRANSACTION=true
	else
		echo "$UTXOS UTXOs in $ADDR below $MIN, nothing to do..."
	fi
done

rm -rf "$DB"

echo "Consolidation completed"
