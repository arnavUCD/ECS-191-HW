"""The shared P2P group ledger (milestone 7): a port of the Swift `LedgerEngine` money rules.

``rules`` holds the pure arithmetic (splits, balances, the settlement plan, the payment-attempt
state machine). ``group`` holds the stored group aggregate and its wire format. ``commands`` runs
one authorized command against an aggregate. Shared parity fixtures prove Swift and Python agree.
"""
