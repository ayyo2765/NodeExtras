# NodeExtras
Misc scripts for working with bitcoin-like coins

This script has been at least lightly tested, but come with no warranty whatsoever for any purpose. Use at your own risk.

See comments at the top of each script for usage information.

## Sending/Spending

### consolidateUTXO.sh
Looks for unspent transactions below a set limit and spends them back to the same address. This consolidates them into one output.
