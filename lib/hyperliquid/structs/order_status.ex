#The <status> string returned has the following possible values:


# open - Placed successfully
# filled - Filled
# canceled - Canceled by user
# triggered - Trigger order triggered
# rejected - Rejected at time of placement
# marginCanceled - Canceled because insufficient margin to fill
# vaultWithdrawalCanceled - Vaults only. Canceled due to a users withdrawal from vault
# openInterestCapCanceled - Canceled due to order being too aggressive when open interest was at cap
# selfTradeCanceled - Canceled due to self-trade prevention
# reduceOnlyCanceled - Canceled reduced-only order that does not reduce position
# siblingFilledCanceled - TP/SL only. Canceled due to sibling ordering being filled
# delistedCanceled - Canceled due to asset delisting
# liquidatedCanceled - Canceled due to liquidation
# scheduledCancel - API only. Canceled due to exceeding scheduled cancel deadline (dead man's switch)
